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
  # is a LOGGING redactor, not a content rewriter. Returning the
  # sanitized text from public APIs would silently corrupt operator
  # workflows that rely on parsing the original output.
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
      /(?<prefix>(?:password|passwd|secret|token|api[_-]?key|access[_-]?key)\s*[=:]\s*)["']?[^\s"']{8,}["']?/i,

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
      /(?<prefix>x-vault-token\s*[=:]\s*)\S+/i
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

      out = text.to_s.dup
      PATTERNS.each do |pattern|
        out.gsub!(pattern) do |match|
          # Preserve named captures (e.g. "password=" prefix) so the
          # redaction is still locatable in the log line.
          prefix = Regexp.last_match[:prefix] rescue nil
          prefix ? "#{prefix}#{REDACTED}" : REDACTED
        end
      end

      truncate_for_log(out)
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
