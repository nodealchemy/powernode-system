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
      return nil if node_module.gitea_repo_full_name.blank?
      return nil if ref.blank?

      owner, repo = node_module.gitea_repo_full_name.split("/", 2)
      return nil if owner.blank? || repo.blank?

      self.class.adapter.fetch_file(
        owner: owner, repo: repo, path: path, ref: ref
      )
    rescue StandardError => e
      Rails.logger.warn("[ManifestFetchService] fetch failed for " \
                        "#{node_module&.gitea_repo_full_name}@#{ref}: " \
                        "#{e.class}: #{e.message}")
      nil
    end

    # === Adapters ===

    class GiteaFetchAdapter
      def fetch_file(owner:, repo:, path:, ref:)
        return nil unless defined?(::Devops::Git::GiteaApiClient)

        credential = ::Devops::GitCredential.find_by(provider_type: "gitea", status: "active")
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
