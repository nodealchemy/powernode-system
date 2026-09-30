# frozen_string_literal: true

require "fileutils"
require "open3"
require "shellwords"
require "tempfile"

module System
  module Gitops
    # Clone or fast-forward-pull a GitopsRepository's working tree into a
    # local directory under `tmp/gitops/<account_id>/<repository_id>/`.
    # Returns a Result with the working-tree path + commit SHA, or an error.
    #
    # Authentication:
    #   - HTTPS without `vault_credential_path`: anonymous clone (public repos).
    #   - HTTPS with `vault_credential_path`: reads `{username, password}` from
    #     Vault KV and uses HTTP Basic via env var GIT_ASKPASS shim (not
    #     URL-embedded — prevents leaking creds into git history / shell logs).
    #   - SSH with `vault_credential_path`: reads `{ssh_key}` from Vault KV
    #     and writes to a tempfile referenced via GIT_SSH_COMMAND.
    #
    # Host verification (IMP-1e5db5e6aefb): every SSH remote is verified
    # against the repository's recorded host key (GitopsRepository
    # #ssh_host_keys, see System::Gitops::RepositoryHostKey), rendered into a
    # per-call 0600 known_hosts file and connected with the exact option set
    # System::SshExecutionService#with_host_verification uses. A repository
    # with no recorded key is keyscanned and pinned on first use; a host that
    # presents a key other than the recorded one fails the sync with the
    # named reason HOST_KEY_MISMATCH_REASON, and the recorded key is never
    # replaced by this service. HTTPS remotes are untouched.
    #
    # Reference: comprehensive stabilization sweep P5.
    class RepoSyncService
      # Raised when the Vault payload at `vault_credential_path` does not carry
      # the key the chosen auth branch needs. Without it the two branches fail
      # in ways that read as anything BUT a credential problem — see
      # #require_creds!.
      class CredentialShapeError < StandardError; end

      # The git host presented a key other than the recorded one. Message
      # carries host, port and recorded FINGERPRINTS only.
      class HostKeyMismatchError < StandardError; end
      # No key is recorded and the host could not be scanned; the sync refuses
      # rather than connect unverified.
      class HostKeyUnavailableError < StandardError; end
      # The repo_url is neither https nor an ssh endpoint this service can
      # pin (git+ssh://, git://, file://, a bare path, an unparseable host).
      # git would pick a transport of its own for it, so git never runs.
      class UnsupportedRemoteError < StandardError; end

      HOST_KEY_MISMATCH_REASON    = "host_key_mismatch"
      HOST_KEY_UNAVAILABLE_REASON = "host_key_unavailable"
      UNSUPPORTED_REMOTE_REASON   = "unsupported_remote"
      HOST_KEY_VERIFICATION_FAILED = "Host key verification failed"

      # `reason` is set only for the named host-key outcomes; the sync run's
      # error_message carries "<reason>: ..." so an operator reading the
      # timeline sees the same word.
      Result = Struct.new(:ok?, :work_tree_path, :commit_sha, :error, :reason, keyword_init: true)

      WORK_TREE_ROOT = Rails.root.join("tmp/gitops")
      CLONE_TIMEOUT_SEC = 60

      def self.sync!(repository)
        new(repository).sync!
      end

      def initialize(repository)
        @repository = repository
      end

      def sync!
        FileUtils.mkdir_p(work_tree_path)

        if File.exist?(File.join(work_tree_path, ".git"))
          fast_forward
        else
          clone_fresh
        end

        commit_sha = read_commit_sha
        Result.new(ok?: true, work_tree_path: work_tree_path, commit_sha: commit_sha)
      rescue CredentialShapeError => e
        # NOT the IMP-7e549d7506cf pattern this rescue block otherwise fixes:
        # this exception's message is deliberately, reviewably safe BY
        # DESIGN — see #require_creds!'s own header comment — reporting
        # presence/shape/key NAMES only, never a credential value. Forwarding
        # it (including the class name) verbatim is intentional and is
        # pinned by the "wrong-shaped credential payload" spec examples.
        Rails.logger.error("[Gitops::RepoSync] #{@repository.id}: #{e.class}: #{e.message}")
        Result.new(ok?: false, error: "#{e.class}: #{e.message}")
      rescue HostKeyMismatchError => e
        # Safe by design like CredentialShapeError: host, port and recorded
        # fingerprints only (see #host_key_mismatch!). The stored key is left
        # exactly as it was — only an operator can record the new one.
        Rails.logger.warn("[Gitops::RepoSync] #{@repository.id}: #{HOST_KEY_MISMATCH_REASON}: #{e.message}")
        ::System::Gitops::RepositoryHostKey.emit_mismatch!(@repository, @host_keys)
        Result.new(ok?: false, reason: HOST_KEY_MISMATCH_REASON, error: "#{HOST_KEY_MISMATCH_REASON}: #{e.message}")
      rescue HostKeyUnavailableError => e
        Rails.logger.warn("[Gitops::RepoSync] #{@repository.id}: #{HOST_KEY_UNAVAILABLE_REASON}: #{e.message}")
        Result.new(ok?: false, reason: HOST_KEY_UNAVAILABLE_REASON, error: "#{HOST_KEY_UNAVAILABLE_REASON}: #{e.message}")
      rescue UnsupportedRemoteError => e
        Rails.logger.warn("[Gitops::RepoSync] #{@repository.id}: #{UNSUPPORTED_REMOTE_REASON}: #{e.message}")
        Result.new(ok?: false, reason: UNSUPPORTED_REMOTE_REASON, error: "#{UNSUPPORTED_REMOTE_REASON}: #{e.message}")
      rescue StandardError => e
        Rails.logger.error("[Gitops::RepoSync] #{@repository.id}: #{e.class}: #{e.message}")
        Result.new(ok?: false, error: "Repository sync failed")
      end

      private

      def work_tree_path
        @work_tree_path ||= WORK_TREE_ROOT.join(@repository.account_id.to_s, @repository.id.to_s).to_s
      end

      # `--` closes git's option parsing before the operator-controlled
      # positionals (branch is also refused by the model when it starts with
      # "-"; repo_url by the scheme validation). `git reset --hard` takes no
      # `--` before a tree-ish (that form means pathspecs), and
      # "origin/<branch>" cannot start with "-".
      def clone_fresh
        FileUtils.rm_rf(work_tree_path)
        run_git!("clone", "--branch", @repository.branch, "--single-branch", "--depth", "1",
                 "--", @repository.repo_url, work_tree_path,
                 cwd: WORK_TREE_ROOT.to_s)
      end

      def fast_forward
        run_git!("fetch", "--", "origin", @repository.branch, cwd: work_tree_path)
        run_git!("reset", "--hard", "origin/#{@repository.branch}", cwd: work_tree_path)
      end

      def read_commit_sha
        out, _err, status = Open3.capture3("git", "rev-parse", "HEAD", chdir: work_tree_path)
        raise "rev-parse failed (#{status.exitstatus})" unless status.success?
        out.strip
      end

      def run_git!(*args, cwd:)
        env = build_git_env
        out, err, status = Open3.capture3(env, "git", *args, chdir: cwd)
        unless status.success?
          host_key_mismatch! if host_key_mismatch?(err)
          # Two-pass sanitization. The git-specific regex catches the
          # exact `https://user:pat@host/` URL shape git's own error
          # output emits. ShellOutputSanitizer then catches the
          # everything-else cases: bare PATs (ghp_*, github_pat_*),
          # Bearer headers from credential-helper output, JWT-shaped
          # subject names, etc. Layered defense — the URL regex is
          # cheap + specific; the sanitizer is broader + slightly
          # heavier; running both adds <1ms on short stderrs.
          sanitized = err.to_s.gsub(/(https?:\/\/)[^:@]+:[^@]+@/, '\1[REDACTED]@')
          sanitized = ::System::ShellOutputSanitizer.redact(sanitized)
          raise "git #{args.first} failed: #{sanitized.to_s.strip}"
        end
        [ out, err ]
      ensure
        cleanup_secret_files!
      end

      # Delete the one-shot askpass / ssh-key files written by build_git_env so the
      # git password and SSH key never linger on disk after the command, and
      # unlink THIS call's known_hosts tempfile. Runs on every run_git! exit
      # (success or raise). The askpass / ssh-key paths are deterministic; the
      # known_hosts is per-call (see #write_known_hosts!) and only the one
      # this call wrote is removed.
      def cleanup_secret_files!
        [ "#{work_tree_path}.askpass", "#{work_tree_path}.ssh_key" ].each do |path|
          File.delete(path) if File.exist?(path)
        end
        @known_hosts_file&.close!
        @known_hosts_file = nil
      rescue StandardError => e
        Rails.logger.warn("[Gitops::RepoSync] secret-file cleanup failed: #{e.message}")
      end

      # Builds an env hash with Git auth configured, depending on the
      # repository's vault_credential_path — and, for an SSH remote, host
      # verification whether or not a credential is configured. Returns {}
      # for anonymous public HTTPS clones.
      #
      # Dispatch is on the repository's own predicates (the same ones its
      # credential contract and validation use). There is no third arm: git
      # decides the transport from the URL, and running it with an
      # environment this service did not build — git+ssh:// would go to the
      # PATH ssh and the service user's known_hosts, git:// is cleartext,
      # file:// clones a hub-local directory — is exactly the unverified
      # connection the pin exists to prevent. Fails closed, before git.
      def build_git_env
        if @repository.ssh_remote?
          build_ssh_env
        elsif @repository.https_remote?
          build_https_env
        else
          raise UnsupportedRemoteError,
                "#{@repository.repo_url} is neither an https:// URL nor a parseable ssh remote " \
                "(ssh://[user@]host[:port]/path or [user@]host:path); refusing to run git"
        end
      end

      def build_https_env
        creds = fetch_required_creds
        return {} unless creds

        # Build a one-shot askpass that answers both git prompts
        askpass = build_askpass_script(creds["username"], creds["password"])
        { "GIT_ASKPASS" => askpass, "GIT_TERMINAL_PROMPT" => "0" }
      end

      # Credentials FIRST (local, cheap, and the shape guard must refuse before
      # anything touches the network), then the host key, then the command.
      # `-F /dev/null` and the option set are exactly
      # SshExecutionService#with_host_verification's, for the same reasons
      # documented there: no ssh_config, no global known_hosts, no DNS or
      # KnownHostsCommand trust source, and ssh may not add entries of its
      # own to the per-call file.
      def build_ssh_env
        creds = fetch_required_creds
        ssh_key_file = creds && build_ssh_key_file(creds["ssh_key"])

        known_hosts = write_known_hosts!(host_keys)

        # GIT_SSH_COMMAND is a shell string: the two file paths are the only
        # words that can carry shell metacharacters, so they alone are
        # escaped; the option words are fixed literals and the alias is
        # ALIAS_FORMAT-safe.
        words = [
          "ssh",
          "-F", "/dev/null",
          "-o", "StrictHostKeyChecking=yes",
          "-o", "UserKnownHostsFile=#{Shellwords.escape(known_hosts)}",
          "-o", "GlobalKnownHostsFile=/dev/null",
          "-o", "HostKeyAlias=#{host_alias}",
          "-o", "CheckHostIP=no",
          "-o", "UpdateHostKeys=no",
          "-o", "VerifyHostKeyDNS=no"
        ]
        words.push("-i", Shellwords.escape(ssh_key_file), "-o", "IdentitiesOnly=yes") if ssh_key_file

        { "GIT_SSH_COMMAND" => words.join(" ") }
      end

      # The Vault payload for this repository, shape-checked, or nil when no
      # credential path is configured or Vault could not be read (the
      # pre-existing anonymous fallback). Raises CredentialShapeError.
      def fetch_required_creds
        return nil if @repository.vault_credential_path.blank?

        creds = fetch_vault_creds
        return nil unless creds

        # The required key set comes from the REPOSITORY, not from a literal
        # here, so the operator surfaces that advertise it (serialize_repo,
        # serialize_gitops_repository, and the credential-path probe on
        # POST /api/v1/admin_settings/vault/test) cannot drift from what this
        # branch actually enforces. IMP-0f914db2c7cf.
        require_creds!(creds, *Array(@repository.required_credential_keys))
        creds
      end

      # The recorded host keys, or — when NO record exists — the keys a live
      # scan of the remote returns, recorded as trust-on-first-use and
      # announced. Memoized per sync: fetch + reset share one answer, and a
      # first-use scan happens once. Raises HostKeyUnavailableError when there
      # is nothing to verify against; this service never connects unverified.
      #
      # Trust on first use is keyed on the ABSENCE of a record, not on the
      # record yielding no usable key: a present document whose entries no
      # longer validate (corrupt column, a key type since dropped) refuses
      # and is left alone — scanning would replace an explicit pin with
      # whatever the network said.
      def host_keys
        return @host_keys if defined?(@host_keys)

        if ::System::Gitops::RepositoryHostKey.recorded?(@repository)
          recorded = ::System::Gitops::RepositoryHostKey.recorded_for(@repository)
          if recorded.empty?
            raise HostKeyUnavailableError,
                  "the recorded host key for this repository is unreadable (no entry validates); it was NOT " \
                  "replaced. Re-record the host's key on the repository (ssh_host_key) after confirming it out of band."
          end
          return @host_keys = recorded
        end

        endpoint = ::System::Gitops::SshRemote.parse(@repository.repo_url)
        raise HostKeyUnavailableError, "#{@repository.repo_url} is not a parseable ssh remote" unless endpoint

        scanned = ::System::Gitops::RepositoryHostKey.scan(host: endpoint.host, port: endpoint.port)
        if scanned.empty?
          raise HostKeyUnavailableError,
                "no host key recorded for #{endpoint.host}:#{endpoint.port} and ssh-keyscan returned none; " \
                "refusing to clone unverified. Record the host key on the repository (ssh_host_key) or retry."
        end

        ::System::Gitops::RepositoryHostKey.record!(@repository, scanned, source: "tofu")
        ::System::Gitops::RepositoryHostKey.emit_recorded!(@repository, scanned, source: "tofu")
        Rails.logger.info(
          "[Gitops::RepoSync] #{@repository.id}: recorded host key on first use for " \
          "#{endpoint.host}:#{endpoint.port} (#{::System::SshHostKeys.fingerprints(scanned).join(', ')})"
        )
        @host_keys = scanned
      end

      def host_alias
        ::System::Gitops::RepositoryHostKey.alias_for(@repository)
      end

      # A per-call UNIQUE 0600 tempfile holding only this repository's
      # line(s) — the SshExecutionService#with_host_verification pattern —
      # unlinked by cleanup_secret_files! on every run_git! exit. Unique, not
      # a fixed path beside the work tree: the cron tick, sync_now, the MCP
      # verbs and the skill all run one repository's sync inline with no
      # lock, and a shared path let one call's cleanup delete the file
      # another call's ssh was about to read, which ssh reports as "No ...
      # host key is known for <alias> ... Host key verification failed" —
      # a false host_key_mismatch. Returns the path.
      def write_known_hosts!(entries)
        file = Tempfile.new([ "gitops-known_hosts", "" ])
        File.chmod(0o600, file.path)
        file.write(::System::SshHostKeys.known_hosts(host_alias, entries))
        file.close
        @known_hosts_file = file
        file.path
      end

      # Mirrors SshExecutionService#host_key_mismatch? MINUS its exit-code
      # clause: that service spawns ssh itself and sees ssh's 255, whereas
      # this one spawns git, which relays ssh's stderr and then dies with its
      # OWN code (128) — ssh's 255 never reaches here. Called only on a failed
      # status. The discriminator is: keys were verified against, ssh's own
      # strict-checking text, AND this repository's alias in that text (ssh
      # names the alias), so a remote hook printing the same words is not
      # read as a mismatch about this host. A host presenting only key TYPES
      # absent from the recorded set ("No ED25519 host key is known for
      # <alias> ... Host key verification failed") is classified the same
      # way, deliberately: it did not present a recorded key.
      def host_key_mismatch?(err)
        stderr = err.to_s
        defined?(@host_keys) && @host_keys.present? &&
          stderr.include?(HOST_KEY_VERIFICATION_FAILED) && stderr.include?(host_alias)
      end

      def host_key_mismatch!
        endpoint = ::System::Gitops::SshRemote.parse(@repository.repo_url)
        fingerprints = ::System::SshHostKeys.fingerprints(@host_keys)
        raise HostKeyMismatchError,
              "the git host #{endpoint&.host}:#{endpoint&.port} did not present a recorded key " \
              "(recorded fingerprints: #{fingerprints.join(', ')}). The stored key was NOT updated. " \
              "Either the host was legitimately rekeyed — record its new key on the repository " \
              "(ssh_host_key) after confirming it out of band — or a different host is answering at its address."
      end

      # Fail with one honest "the credential payload is the wrong shape" instead
      # of letting each auth branch invent its own misleading symptom. The HTTPS
      # branch is nil-TOLERANT (`password.to_s`) and would attempt auth with a
      # BLANK password, which surfaces as a plain permission denial; the SSH
      # branch is nil-FRAGILE (`nil.end_with?`) and would raise NoMethodError,
      # which sync!'s blanket rescue writes verbatim into
      # GitopsSyncRun#error_message. Neither reads as a credential problem.
      #
      # Reports PRESENCE, SHAPE and KEY NAMES only — never a credential value.
      def require_creds!(creds, *required)
        # An EMPTY contract must refuse, not wave the clone through unchecked.
        # Unreachable today — the scheme dispatch lives on the repository and
        # every arm that gets here has keys — but the coupling between this
        # file's branches and the model's is by convention, so a future branch
        # added on one side only fails CLOSED instead of silently enforcing
        # nothing and letting build_askpass_script write a blank password.
        if required.compact.empty?
          raise CredentialShapeError,
                "No credential contract for #{@repository.repo_url} — refusing to authenticate " \
                "with an unchecked payload from #{@repository.vault_credential_path}"
        end

        unless creds.is_a?(Hash)
          raise CredentialShapeError,
                "Vault credential payload at #{@repository.vault_credential_path} is not a Hash " \
                "(got #{creds.class})"
        end

        missing = required.reject { |name| creds[name].to_s.present? }
        return if missing.empty?

        raise CredentialShapeError,
              "Vault credential payload at #{@repository.vault_credential_path} is missing " \
              "#{missing.join(', ')} (keys present: #{creds.keys.map(&:to_s).sort.join(', ')})"
      end

      def fetch_vault_creds
        ::Security::VaultClient.read_secret(@repository.vault_credential_path)
      rescue StandardError => e
        Rails.logger.warn("[Gitops::RepoSync] Vault credential fetch failed: #{e.message}")
        nil
      end

      def build_askpass_script(username, password)
        # Single-use script that answers whichever prompt git asks. Git invokes
        # GIT_ASKPASS once PER PROMPT with the prompt text as $1, and for a
        # remote carrying no userinfo it asks "Username for '...'" FIRST. This
        # shim previously ignored $1 and echoed the password every time, so
        # such a clone authenticated as <password>:<password> and the Vault
        # `username` was read and discarded. The comment here asserted the
        # username "is embedded in the URL via the standard Git mechanism" —
        # nothing put it there; clone_fresh uses repo_url verbatim.
        path = "#{work_tree_path}.askpass"
        File.open(path, "w", 0o700) do |f|
          f.write(<<~SH)
            #!/bin/bash
            case "$1" in
              Username*) echo '#{shell_quote(username)}' ;;
              *)         echo '#{shell_quote(password)}' ;;
            esac
          SH
        end
        FileUtils.chmod(0o700, path)
        path
      end

      # Close a single-quoted shell literal, emit a quoted quote, reopen. The
      # value never reaches a log or an exception — only this one-shot file.
      def shell_quote(value)
        value.to_s.gsub("'", %q('"'"'))
      end

      def build_ssh_key_file(key_content)
        path = "#{work_tree_path}.ssh_key"
        File.open(path, "w", 0o600) do |f|
          f.write(key_content)
          f.write("\n") unless key_content.end_with?("\n")
        end
        FileUtils.chmod(0o600, path)
        path
      end
    end
  end
end
