# frozen_string_literal: true

require "base64"
require "digest"
require "json"
require "net/http"
require "uri"

module System
  # Reads one module artifact's OCI manifest from the registry: the one
  # registry-manifest client behind OciLayerDigestFetcher (the publications
  # controller's erofs-layer backfill) and NativeModuleBuildOrchestrator's
  # stale re-tag guard.
  #
  # Auth: the account's Gitea PAT as a Basic-auth password (any username) —
  # registries hosted on the same Gitea instance accept it. No new secret
  # surface.
  #
  # Best-effort: #fetch returns nil on ANY failure (no PAT, an unsplittable
  # ref, a non-2xx, an unparseable manifest, a manifest with no layers, a
  # network error), and callers must read nil as "not measured", never as
  # "clean". #lookup additionally tells a 404 (the tag definitively does not
  # exist) apart from an outage.
  module OciManifestClient
    ACCEPT = [
      "application/vnd.oci.image.manifest.v1+json",
      "application/vnd.docker.distribution.manifest.v2+json"
    ].join(",").freeze

    # manifest_digest — the digest of the manifest itself, which is what
    #   module-forge-build.sh's RESULT JSON reports as oci_digest
    #   (`oras manifest fetch --descriptor`).
    # erofs_layer — the erofs layer descriptor (falling back to the first
    #   layer); its digest is what a native publish records as
    #   NodeModuleVersion#oci_digest and what nodes report as running.
    Manifest = Struct.new(:manifest_digest, :erofs_layer, keyword_init: true) do
      def layer_digest
        erofs_layer && erofs_layer["digest"].presence
      end
    end

    # status:
    #   :found       — manifest read; `manifest` is set
    #   :not_found   — the registry answered 404: the tag definitively does not
    #                  exist (e.g. a module never pushed). Not an outage.
    #   :unavailable — nothing could be measured: no PAT, an unsplittable ref,
    #                  any other non-2xx, an unusable manifest, a network error
    Lookup = Struct.new(:status, :manifest, keyword_init: true)

    module_function

    # @return [Manifest, nil] the manifest when found; nil otherwise
    def fetch(node_module:, oci_ref:)
      lookup(node_module: node_module, oci_ref: oci_ref).manifest
    end

    # @return [Lookup]
    def lookup(node_module:, oci_ref:)
      m = oci_ref.to_s.match(%r{\A([^/]+)/(.+):([^:]+)\z})
      return unavailable unless m

      registry, repo, tag = m[1], m[2], m[3]
      pat = node_module.account.git_provider_credentials.where(auth_type: "personal_access_token").first&.access_token
      return unavailable if pat.blank?

      res = get_manifest(registry, repo, tag, pat)
      return Lookup.new(status: :not_found, manifest: nil) if res.is_a?(Net::HTTPNotFound)
      return unavailable unless res.is_a?(Net::HTTPSuccess)

      body = res.body.to_s
      layers = Array(JSON.parse(body)["layers"])
      erofs = layers.find { |l| l["mediaType"].to_s =~ /erofs/ } || layers.first
      return unavailable unless erofs

      Lookup.new(status: :found, manifest: Manifest.new(
        manifest_digest: res["Docker-Content-Digest"].presence || "sha256:#{Digest::SHA256.hexdigest(body)}",
        erofs_layer: erofs
      ))
    rescue StandardError => e
      Rails.logger.warn "[OciManifestClient] #{oci_ref}: #{e.class}: #{e.message}"
      unavailable
    end

    def unavailable
      Lookup.new(status: :unavailable, manifest: nil)
    end
    private_class_method :unavailable

    def get_manifest(registry, repo, tag, pat)
      uri = URI("https://#{registry}/v2/#{repo}/manifests/#{tag}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 5
      http.read_timeout = 10
      req = Net::HTTP::Get.new(uri.path)
      req["Authorization"] = "Basic " + ::Base64.strict_encode64("ci:#{pat}")
      req["Accept"] = ACCEPT
      http.request(req)
    end
    private_class_method :get_manifest
  end
end
