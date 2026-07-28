# frozen_string_literal: true

module System
  # Detects artifacts that reached the OCI registry but never reached the
  # platform — the "published but unrecorded" class.
  #
  # WHY THIS EXISTS. A module build pushes the artifact and cosign-signs it
  # BEFORE it notifies the platform. Every failure after that point leaves the
  # registry holding a real, signed artifact while NodeModuleVersion knows
  # nothing about it. The run goes red, so it looks like the build broke — when
  # in fact the build succeeded and only the bookkeeping was lost. On
  # 2026-07-27 that was a TLS trust failure in the notify preflight
  # (self-signed platform chain, untrusted in the build container) and it hid a
  # second, unrelated fault underneath it for days.
  #
  # A notify step can fail for many reasons — bad token, wrong API base,
  # unreachable platform, 422 from manifest validation. Rather than enumerate
  # them, this compares the two sides directly, so any current or future cause
  # shows up as the same finding.
  #
  # THIS IS NOT A STALENESS SWEEP. It never compares source age against build
  # age. Modules here are built on-demand and event-driven (CVE advisories,
  # upstream changes), so a module whose newest build predates its newest commit
  # is normal and is NOT reported. The only question asked is: did something we
  # published get recorded?
  class ModulePublicationIntegrityService
    Finding = Struct.new(:module_name, :repo, :registry_tags, :recorded_tags,
                         :unrecorded_tags, :error, keyword_init: true) do
      def ok?      = error.nil? && unrecorded_tags.empty?
      def to_h     = super.merge(ok: ok?)
    end

    def initialize(account:)
      @account = account
    end

    # Returns one Finding per module inspected.
    def check(module_name: nil)
      modules_to_check(module_name).map { |m| check_module(m) }
    end

    private

    def modules_to_check(module_name)
      scope = @account.system_node_modules
      return scope.where(name: module_name) if module_name.present?

      # Only modules the platform believes CI publishes for. A module with no
      # published version and no repo binding has no registry side to compare.
      scope.where.not(gitea_repo_full_name: nil)
    end

    def check_module(node_module)
      # Mirror the fallback the rest of the pipeline uses, so a module whose
      # binding was never set is still checked against the repo CI would push to.
      repo = node_module.gitea_repo_full_name.presence || "powernode/#{node_module.name}"

      tags = registry_tags(repo)
      return Finding.new(module_name: node_module.name, repo: repo, error: tags[:error],
                         registry_tags: [], recorded_tags: [], unrecorded_tags: []) if tags.is_a?(Hash) && tags[:error]

      recorded = node_module.versions.filter_map { |v| v.config&.dig("git_tag").presence }.uniq

      Finding.new(
        module_name:     node_module.name,
        repo:            repo,
        registry_tags:   tags,
        recorded_tags:   recorded,
        unrecorded_tags: tags - recorded,
        error:           nil
      )
    end

    # `oras repo tags <host>/<repo>` against a THROWAWAY DOCKER_CONFIG — never
    # the shared ~/.docker/config.json, since Puma serves many accounts
    # concurrently. Token is piped via stdin, never argv.
    def registry_tags(repo)
      host = ::System::DiskImageRegistryConfig.registry_host(account: @account)
      return { error: "registry host not configured" } if host.blank?

      user  = ::System::DiskImageRegistryConfig.registry_user(account: @account)
      token = ::System::DiskImageRegistryConfig.registry_token(account: @account)

      Dir.mktmpdir("powernode-integrity-") do |dir|
        env = { "DOCKER_CONFIG" => dir }

        if user.present? && token.present?
          _o, login_err, login_status = ::Open3.capture3(
            env, "oras", "login", host, "--username", user, "--password-stdin",
            stdin_data: token.to_s
          )
          unless login_status.success?
            return { error: "registry login failed: " \
                            "#{::System::ShellOutputSanitizer.redact(login_err.presence) || "exit #{login_status.exitstatus}"}" }
          end
        end

        out, err, status = ::Open3.capture3(env, "oras", "repo", "tags", "#{host}/#{repo}")
        unless status.success?
          # A repo that has never been pushed to is not an error — it is simply
          # a module CI has not built yet, and reporting it as a failure would
          # bury the findings that matter.
          redacted = ::System::ShellOutputSanitizer.redact(err.presence).to_s
          return [] if redacted.match?(/not found|NAME_UNKNOWN|repository name not known/i)

          return { error: redacted.presence || "oras repo tags exit #{status.exitstatus}" }
        end

        out.to_s.split("\n").map(&:strip).reject(&:blank?)
      end
    rescue StandardError => e
      { error: "#{e.class}: #{e.message}" }
    end
  end
end
