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
          # Strip credentials from error output before logging
          sanitized = err.to_s.gsub(/(https?:\/\/)[^:@]+:[^@]+@/, '\1[REDACTED]@')
          raise "git #{args.first} failed: #{sanitized.strip}"
        end
        [out, err]
      end

      # Builds an env hash with Git auth configured, depending on the
      # repository's vault_credential_path. Returns {} for anonymous public
      # HTTPS clones.
      def build_git_env
        return {} if @repository.vault_credential_path.blank?

        creds = fetch_vault_creds
        return {} unless creds

        if @repository.repo_url.start_with?("https://", "http://")
          # Build a one-shot askpass that returns the password
          askpass = build_askpass_script(creds["username"], creds["password"])
          { "GIT_ASKPASS" => askpass, "GIT_TERMINAL_PROMPT" => "0" }
        elsif @repository.repo_url.start_with?("git@", "ssh://")
          ssh_key_file = build_ssh_key_file(creds["ssh_key"])
          ssh_command = "ssh -i #{ssh_key_file} -o StrictHostKeyChecking=no -o IdentitiesOnly=yes"
          { "GIT_SSH_COMMAND" => ssh_command }
        else
          {}
        end
      end

      def fetch_vault_creds
        ::Security::VaultClient.read_secret(@repository.vault_credential_path)
      rescue StandardError => e
        Rails.logger.warn("[Gitops::RepoSync] Vault credential fetch failed: #{e.message}")
        nil
      end

      def build_askpass_script(username, password)
        # Single-use script that echoes the password. Username is embedded
        # in the URL via the standard Git mechanism.
        path = "#{work_tree_path}.askpass"
        File.open(path, "w", 0o700) do |f|
          f.write("#!/bin/bash\necho '#{password.to_s.gsub("'", %q['"'"'])}'\n")
        end
        FileUtils.chmod(0o700, path)
        path
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
