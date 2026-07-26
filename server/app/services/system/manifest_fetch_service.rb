# frozen_string_literal: true

module System
  # Fetches a NodeModule's manifest.yaml from its source Gitea repository
  # at a specific tag/ref. Used by the Gitea webhook receiver to refresh
  # the module's spec/lifecycle declarations whenever a tag publishes
  # — without this, the platform learns about the OCI artifact but
  # never sees that the manifest's protected_spec or init_* changed.
  #
  # Adapter pattern mirrors ModuleOciIngestService:
  #   - GiteaFetchAdapter (production)  uses Devops::Git::GiteaApiClient
  #   - LocalFetchAdapter   (test/dev) returns a stubbed yaml hash so
  #     specs can exercise the controller without a real Gitea.
  #
  # Failure mode: returns nil on any error (credential missing, file not
  # found, network error). Callers should log + continue — manifest
  # fetch is enrichment, not gating.
  class ManifestFetchService
    DEFAULT_PATH = "manifest.yaml"

    # Platform modules (gitea_repo_full_name blank) carry their manifest in the
    # shared module source repo under modules/<name>/. Mirrors
    # ModuleBuildPlannerService::CI_BUILD_SOURCE_REPO_DEFAULT — the repo the
    # builder itself clones.
    PLATFORM_SOURCE_REPO_DEFAULT = "powernode/powernode-system"

    class FetchError < StandardError; end

    class << self
      def adapter
        @adapter ||= build_adapter
      end

      def adapter=(replacement)
        @adapter = replacement
      end

      def reset!
        @adapter = nil
      end

      def fetch(node_module:, ref:, path: DEFAULT_PATH)
        new.fetch(node_module: node_module, ref: ref, path: path)
      end

      private

      def build_adapter
        mode = ENV.fetch("POWERNODE_MANIFEST_FETCH_MODE", default_mode_for_env)
        case mode
        when "gitea" then GiteaFetchAdapter.new
        when "local" then LocalFetchAdapter.new
        else raise FetchError, "Unknown POWERNODE_MANIFEST_FETCH_MODE: #{mode.inspect}"
        end
      end

      def default_mode_for_env
        Rails.env.production? ? "gitea" : "local"
      end
    end

    def fetch(node_module:, ref:, path: DEFAULT_PATH)
      return nil unless node_module
      return nil if ref.blank?

      source = resolve_source(node_module, path)
      return nil unless source

      self.class.adapter.fetch_file(
        owner: source[:owner], repo: source[:repo], path: source[:path], ref: ref
      )
    rescue StandardError => e
      Rails.logger.warn("[ManifestFetchService] fetch failed for " \
                        "#{node_module&.name}@#{ref}: #{e.class}: #{e.message}")
      nil
    end

    # Where a module's manifest.yaml lives. Two shapes exist and only one used
    # to be handled:
    #
    #   per-repo modules  gitea_repo_full_name set -> <owner>/<repo>:manifest.yaml
    #   PLATFORM modules  gitea_repo_full_name BLANK -> the platform module source
    #                     repo, at modules/<name>/manifest.yaml
    #
    # Returning nil for the second shape meant `ModulePublicationProcessor`'s
    # "refresh manifest FIRST" step silently did nothing for every platform
    # module — system-base, the hub apps, the reverse proxy, the extensions.
    # Their ModuleService/user/group rows were therefore frozen at whatever the
    # module was first imported with, so the platform served a manifest that no
    # longer matched the artifact it was serving alongside it. Observed
    # 2026-07-26 on ops-hub: reverse-proxy-traefik had ZERO ModuleService rows,
    # so a build that added a service could not be described to any node, and
    # the operator had to hand-build the manifest JSON to deliver it.
    #
    # The platform path deliberately mirrors how the artifact was BUILT:
    # module-forge-build.sh clones the same source repo and reads
    # modules/$MODULE/manifest.yaml at the same BUILD_SHA that becomes this
    # `ref`. So the manifest imported here is, by construction, the one the
    # blob was built from — not an approximation from some other revision.
    def resolve_source(node_module, path)
      if node_module.gitea_repo_full_name.present?
        owner, repo = node_module.gitea_repo_full_name.split("/", 2)
        return nil if owner.blank? || repo.blank?
        return { owner: owner, repo: repo, path: path }
      end

      return nil if node_module.name.blank?

      owner, repo = platform_source_repo.to_s.split("/", 2)
      return nil if owner.blank? || repo.blank?

      # Only the default filename maps into the modules/<name>/ tree; an
      # explicit path is honoured verbatim so callers can still target
      # something else in the same repo.
      resolved = path == DEFAULT_PATH ? "modules/#{node_module.name}/#{DEFAULT_PATH}" : path
      { owner: owner, repo: repo, path: resolved }
    end

    # Same resolution order as ModuleBuildPlannerService — SiteSetting, then
    # env, then the default — so the manifest is read from exactly the repo the
    # builder was pointed at.
    def platform_source_repo
      ::SiteSetting.get("ci_build_source_repo").presence ||
        ENV["POWERNODE_CI_BUILD_SOURCE_REPO"].presence ||
        PLATFORM_SOURCE_REPO_DEFAULT
    end

    # === Adapters ===

    class GiteaFetchAdapter
      def fetch_file(owner:, repo:, path:, ref:)
        return nil unless defined?(::Devops::Git::GiteaApiClient)

        # Devops::GitCredential doesn't exist — the real model is
        # Devops::GitProviderCredential, scoped through its
        # Devops::GitProvider association (provider_type lives on the
        # provider, not the credential; "active" is the is_active column
        # via the .active scope, not a status string). This path is only
        # reached by node modules that set gitea_repo_full_name (the 5
        # custom per-repo modules) — the NameError was previously
        # silently swallowed by this method's StandardError rescue, so
        # manifest fetch always failed closed (returned nil) for every
        # module on this path.
        provider = ::Devops::GitProvider.find_by(provider_type: "gitea")
        return nil unless provider

        credential = ::Devops::GitProviderCredential.active.for_provider(provider)
                                                     .order(is_default: :desc, created_at: :desc).first
        return nil unless credential

        client = ::Devops::Git::GiteaApiClient.new(credential)
        result = client.get_file_content(owner, repo, path, ref)
        return nil if result.nil?

        # get_file_content returns a normalized hash; the decoded text
        # lives under :content. Reject binary or empty content.
        return nil if result[:is_binary]
        result[:content]
      end
    end

    # In-memory adapter for tests + dev. Specs configure the response
    # via `ManifestFetchService.adapter.stub_yaml = ...` and assert on
    # `last_request` to verify the right ref was queried.
    class LocalFetchAdapter
      attr_accessor :stub_yaml, :stub_error
      attr_reader :last_request

      def initialize
        @stub_yaml = nil
        @stub_error = nil
        @last_request = nil
      end

      def fetch_file(owner:, repo:, path:, ref:)
        @last_request = { owner: owner, repo: repo, path: path, ref: ref }
        raise @stub_error if @stub_error
        @stub_yaml
      end
    end
  end
end
