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
  # Best-effort: nil on ANY failure (no PAT, an unsplittable ref, a non-2xx,
  # an unparseable manifest, a manifest with no layers, a network error).
  # Callers must read nil as "not measured", never as "clean".
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

    module_function

    # @return [Manifest, nil]
    def fetch(node_module:, oci_ref:)
      m = oci_ref.to_s.match(%r{\A([^/]+)/(.+):([^:]+)\z})
      return nil unless m

      registry, repo, tag = m[1], m[2], m[3]
      pat = node_module.account.git_provider_credentials.where(auth_type: "personal_access_token").first&.access_token
      return nil if pat.blank?

      res = get_manifest(registry, repo, tag, pat)
      return nil unless res.is_a?(Net::HTTPSuccess)

      body = res.body.to_s
      layers = Array(JSON.parse(body)["layers"])
      erofs = layers.find { |l| l["mediaType"].to_s =~ /erofs/ } || layers.first
      return nil unless erofs

      Manifest.new(
        manifest_digest: res["Docker-Content-Digest"].presence || "sha256:#{Digest::SHA256.hexdigest(body)}",
        erofs_layer: erofs
      )
    rescue StandardError => e
      Rails.logger.warn "[OciManifestClient] #{oci_ref}: #{e.class}: #{e.message}"
      nil
    end

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
