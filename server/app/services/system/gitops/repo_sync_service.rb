# frozen_string_literal: true

require "fileutils"
require "open3"

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
    # Reference: comprehensive stabilization sweep P5.
    class RepoSyncService
      # Raised when the Vault payload at `vault_credential_path` does not carry
      # the key the chosen auth branch needs. Without it the two branches fail
      # in ways that read as anything BUT a credential problem — see
      # #require_creds!.
      class CredentialShapeError < StandardError; end

      Result = Struct.new(:ok?, :work_tree_path, :commit_sha, :error, keyword_init: true)

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
      rescue StandardError => e
        Rails.logger.error("[Gitops::RepoSync] #{@repository.id}: #{e.class}: #{e.message}")
        Result.new(ok?: false, error: "#{e.class}: #{e.message}")
      end

      private

      def work_tree_path
        @work_tree_path ||= WORK_TREE_ROOT.join(@repository.account_id.to_s, @repository.id.to_s).to_s
      end

      def clone_fresh
        FileUtils.rm_rf(work_tree_path)
        run_git!("clone", "--branch", @repository.branch, "--single-branch", "--depth", "1",
                 @repository.repo_url, work_tree_path,
                 cwd: WORK_TREE_ROOT.to_s)
      end

      def fast_forward
        run_git!("fetch", "origin", @repository.branch, cwd: work_tree_path)
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
      # git password and SSH key never linger on disk after the command. Runs on
      # every run_git! exit (success or raise); paths are deterministic.
      def cleanup_secret_files!
        [ "#{work_tree_path}.askpass", "#{work_tree_path}.ssh_key" ].each do |path|
          File.delete(path) if File.exist?(path)
        end
      rescue StandardError => e
        Rails.logger.warn("[Gitops::RepoSync] secret-file cleanup failed: #{e.message}")
      end

      # Builds an env hash with Git auth configured, depending on the
      # repository's vault_credential_path. Returns {} for anonymous public
      # HTTPS clones.
      def build_git_env
        return {} if @repository.vault_credential_path.blank?

        creds = fetch_vault_creds
        return {} unless creds

        # The required key set comes from the REPOSITORY, not from a literal
        # here, so the operator surfaces that advertise it (serialize_repo,
        # serialize_gitops_repository, and the credential-path probe on
        # POST /api/v1/admin_settings/vault/test) cannot drift from what this
        # branch actually enforces. IMP-0f914db2c7cf.
        required = Array(@repository.required_credential_keys)

        if @repository.repo_url.start_with?("https://", "http://")
          # Build a one-shot askpass that answers both git prompts
          require_creds!(creds, *required)
          askpass = build_askpass_script(creds["username"], creds["password"])
          { "GIT_ASKPASS" => askpass, "GIT_TERMINAL_PROMPT" => "0" }
        elsif @repository.repo_url.start_with?("git@", "ssh://")
          require_creds!(creds, *required)
          ssh_key_file = build_ssh_key_file(creds["ssh_key"])
          ssh_command = "ssh -i #{ssh_key_file} -o StrictHostKeyChecking=no -o IdentitiesOnly=yes"
          { "GIT_SSH_COMMAND" => ssh_command }
        else
          {}
        end
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
