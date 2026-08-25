# frozen_string_literal: true

module System
  # Redacts secrets out of strings that came from a shell — typically
  # the stdout / stderr / command captured by SshExecutionService and
  # the OCI ingest service before any of it lands in Rails.logger.
  #
  # The goal is NOT to be exhaustive (no redactor in the world catches
  # every possible secret shape) — it's to catch the high-frequency
  # forms that leak through cloud-provider CLIs, vault commands,
  # `env | grep`-style debugging, and bash `set -x` traces.
  #
  # Composed of small, fast regex patterns. Order does not matter
  # because we run all of them sequentially on the same string.
  #
  # Apply via:
  #
  #   safe = System::ShellOutputSanitizer.redact(stdout)
  #   Rails.logger.info("[my-service] stdout: #{safe}")
  #
  # The raw stdout is still available to callers that need it — this
  # is primarily a LOGGING redactor, not a content rewriter, and a
  # caller that hands the sanitized text back to a machine consumer
  # parsing the original output would silently corrupt it.
  #
  # The one deliberate exception is a surface that shows stored failure
  # output to a human/agent operator (System::Task#error_message over
  # MCP, IMP-b8af3c3309fe): there the crypto-safety rule that no key
  # material leaves the platform outranks fidelity, so the redacted copy
  # IS the payload. Those callers use .redact_text and own their own
  # length policy.
  class ShellOutputSanitizer
    REDACTED = "[REDACTED]"

    # Each entry is a regex whose match the redactor replaces with
    # REDACTED. \k< name captures preserve a non-secret prefix so the
    # redaction is locatable in logs (e.g. "Bearer [REDACTED]" stays
    # informative even without the actual token).
    PATTERNS = [
      # AWS access key IDs (always 20 chars, AKIA/ASIA/AROA prefix)
      /\b(?:AKIA|ASIA|AROA|AIDA|AGPA)[0-9A-Z]{16}\b/,

      # AWS-style secret access keys: 40 chars of base64 alphabet. To
      # avoid false positives on long base64 blobs that aren't actually
      # secrets, gate on a prefix that almost always appears in CLI
      # output (aws_secret_access_key = ...).
      /(?<prefix>aws_secret_access_key\s*[=:]\s*)["']?[A-Za-z0-9\/+=]{40}["']?/i,

      # Generic "password=…" / "passwd=…" / "secret=…" / "token=…" key=value
      # pairs in command output or env dumps. Captures the key so the
      # redaction is locatable.
      #
      # The optional quote BEFORE the delimiter matters: JSON puts one there
      # ({"password": "…"}, and the {"auths":{…{"auth":"…"}}} that a docker
      # config / registry 401 body carries), and without it the whole JSON
      # family walked straight past this pattern. `key`/`credential`/
      # `passphrase` are bare so SECRET_KEY_BASE-shaped env names — where the
      # keyword is not adjacent to the `=` — still match on their KEY tail.
      /(?<prefix>["']?(?:password|passwd|secret|token|auth|credential|passphrase|api[_-]?key|access[_-]?key|key)["']?\s*[=:]\s*)["']?[^\s"',}]{8,}["']?/i,

      # Credential passed as a SPACE-separated flag value rather than key=value
      # — the shape of the login commands a module build actually runs
      # (`oras login -u ci -p …`, `docker login --password …`, `curl -u user:token`).
      /(?<prefix>--?(?:p|u|password|passwd|pass|user|username|token|secret|key)\s+)\S+/,

      # UPPER_SNAKE env names whose NAME says secret but whose keyword is not
      # adjacent to the `=` — SECRET_KEY_BASE is the one that matters most
      # here, since a `set -x`/`env` dump in a failed platform build carries
      # the platform's own signing secret and the keyword-adjacent pattern
      # above sees only "BASE=".
      /(?<prefix>\b[A-Z][A-Z0-9_]*(?:KEY|SECRET|TOKEN|PASSWORD|PASSWD|CREDENTIAL)[A-Z0-9_]*\s*=\s*)\S+/,

      # .netrc line (`machine host login user password secret`). Matched on the
      # whole line shape rather than on a bare "password <word>", which would
      # gut the far more common prose diagnostic "password authentication
      # failed for user ..." and teach operators to distrust the redactor.
      /(?<prefix>\bmachine\s+\S+\s+login\s+\S+\s+password\s+)\S+/i,

      # Credentials embedded in a URL's userinfo (https://user:token@host).
      # The single most plausible leak in this repo's build output: a git
      # clone/fetch failure echoes the remote verbatim, token included.
      # Keeps the scheme + username so the line stays diagnosable.
      /(?<prefix>[a-z][a-z0-9+.-]*:\/\/[^\s:@\/]+:)[^\s@\/]+(?=@)/i,

      # HTTP Authorization headers — Bearer / Basic / Token
      /(?<prefix>(?:Authorization|Bearer|Basic|Token)\s+)[A-Za-z0-9\-._~+\/=]{16,}/i,

      # JWTs (header.payload.signature, three base64url segments)
      /\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b/,

      # GitHub PAT (classic ghp_) + fine-grained (github_pat_) + OAuth (gho_)
      /\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36,}\b/,
      /\bgithub_pat_[A-Za-z0-9_]{82}\b/,

      # OpenAI-style sk-* keys, Anthropic sk-ant-*, Vault hvs.* tokens
      /\bsk-(?:ant-)?[A-Za-z0-9\-_]{32,}\b/,
      /\bhvs\.[A-Za-z0-9_-]{20,}\b/,

      # SSH private keys appearing in stdout (e.g. `cat ~/.ssh/id_*`)
      /-----BEGIN (?:RSA |OPENSSH |EC |DSA |ENCRYPTED )?PRIVATE KEY-----.*?-----END (?:RSA |OPENSSH |EC |DSA |ENCRYPTED )?PRIVATE KEY-----/m,

      # x-vault-token header / Vault unseal keys
      /(?<prefix>x-vault-token\s*[=:]\s*)\S+/i,

      # CLIPPED private key: a BEGIN header whose END footer never arrived,
      # which is what output cut off mid-key upstream looks like (lego_client
      # slices stderr to 800 bytes BEFORE redacting, and a node agent's
      # captured stdout can end anywhere). The body bytes are still key
      # material, and the block pattern above is anchored on the footer, so it
      # does not see them at all. The type class is wider than that pattern's
      # because cosign's real header is `BEGIN ENCRYPTED SIGSTORE PRIVATE KEY`,
      # which the footer-anchored pattern never matched either.
      #
      # It consumes only PEM-SHAPED continuation lines — a run of >= 16 base64
      # characters, or an RFC 1421 header (Proc-Type/DEK-Info), or a blank line
      # — and stops at the first line that is ordinary prose. Matching to
      # end-of-string instead would delete the actual failure reason every time
      # a tool merely NAMES a key file ("unsupported PEM block ..."), which is
      # strictly worse than the leak it closes. Residual: a final body line
      # under 16 chars is left behind; complete blocks are caught above, and a
      # clipped one has no short final line by construction.
      /-----BEGIN[A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----(?:\r?\n(?:[A-Za-z0-9+\/=]{16,}|(?:Proc-Type|DEK-Info):[^\n]*|))*/
    ].freeze

    # Hard cap so we can never silently truncate large stdouts.
    # Callers that need to log more should reach for level=debug
    # or save to a tempfile rather than embedding in a one-line info.
    MAX_LOG_BYTES = 4_096

    # Redacts secrets out of text. Returns a new String; the input
    # is not mutated. nil-safe — nil in, nil out. Always returns a
    # truncated-to-MAX_LOG_BYTES string if input is longer (with a
    # trailing "...[truncated N bytes]" marker so the operator knows
    # the log line was clipped, not the command).
    def self.redact(text)
      return nil if text.nil?
      return text if text.empty?

      truncate_for_log(redact_text(text))
    end

    # Redaction WITHOUT the log truncation. Split out for callers that own
    # their own size policy — the MCP task serializer redacts once and then
    # applies a per-surface limit (full text on the single-task read, a
    # shorter cap on the list), so it must not inherit MAX_LOG_BYTES. Every
    # secret pattern is identical to .redact; only the length handling differs.
    def self.redact_text(text)
      return nil if text.nil?
      return text if text.empty?

      out = text.to_s.dup
      PATTERNS.each do |pattern|
        out.gsub!(pattern) do |match|
          # Preserve named captures (e.g. "password=" prefix) so the
          # redaction is still locatable in the log line.
          prefix = Regexp.last_match[:prefix] rescue nil
          prefix ? "#{prefix}#{REDACTED}" : REDACTED
        end
      end
      out
    end

    # Convenience for hashes whose values may contain shell output.
    # Recurses into nested hashes + arrays. Used by Rails.logger calls
    # that already build a payload hash and want one-shot redaction.
    def self.redact_payload(obj)
      case obj
      when ::Hash
        obj.each_with_object({}) { |(k, v), out| out[k] = redact_payload(v) }
      when ::Array
        obj.map { |item| redact_payload(item) }
      when ::String
        redact(obj)
      else
        obj
      end
    end

    def self.truncate_for_log(text)
      return text if text.bytesize <= MAX_LOG_BYTES
      truncated = text.byteslice(0, MAX_LOG_BYTES)
      # Don't leave a multi-byte char half-chopped — back off to the
      # last valid UTF-8 boundary if we're in the middle of one.
      truncated.scrub!("")
      "#{truncated}...[truncated #{text.bytesize - MAX_LOG_BYTES} bytes]"
    end
  end
end
