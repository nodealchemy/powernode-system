# frozen_string_literal: true

require "base64"
require "digest"
require "json"
require "net/http"
require "uri"

module System
  # Both digests of one published module artifact, read from its OCI manifest:
  #
  #   manifest_digest — what module-forge-build.sh's RESULT JSON reports as
  #                     oci_digest (`oras manifest fetch --descriptor`)
  #   layer_digest    — the erofs LAYER digest, which is what a native publish
  #                     records as NodeModuleVersion#oci_digest and what nodes
  #                     report in running_module_digests
  #
  # The two never compare with each other, so the stale re-tag guard in
  # NativeModuleBuildOrchestrator needs both: the manifest digest to recognise
  # a re-tag, the layer digest to compare against recorded versions.
  #
  # Same registry auth as OciLayerDigestFetcher (the account's Gitea PAT as a
  # Basic-auth password). Best-effort: returns nil on ANY failure — no PAT, a
  # non-2xx, an unparseable manifest — and every caller must treat nil as
  # "not measured", never as "clean".
  module OciArtifactDigests
    ACCEPT = [
      "application/vnd.oci.image.manifest.v1+json",
      "application/vnd.docker.distribution.manifest.v2+json"
    ].join(",").freeze

    module_function

    # @return [Hash{Symbol=>String}, nil] { manifest_digest:, layer_digest: }
    def resolve(node_module:, oci_ref:)
      m = oci_ref.to_s.match(%r{\A([^/]+)/(.+):([^:]+)\z})
      return nil unless m

      registry, repo, tag = m[1], m[2], m[3]
      pat = node_module.account.git_provider_credentials.where(auth_type: "personal_access_token").first&.access_token
      return nil if pat.blank?

      res = get_manifest(registry, repo, tag, pat)
      return nil unless res.is_a?(Net::HTTPSuccess)

      body = res.body.to_s
      manifest = JSON.parse(body)
      layers = Array(manifest["layers"])
      erofs = layers.find { |l| l["mediaType"].to_s =~ /erofs/ } || layers.first
      return nil unless erofs && erofs["digest"].present?

      manifest_digest = res["Docker-Content-Digest"].presence || "sha256:#{Digest::SHA256.hexdigest(body)}"
      { manifest_digest: manifest_digest, layer_digest: erofs["digest"].to_s }
    rescue StandardError => e
      Rails.logger.warn "[OciArtifactDigests] #{oci_ref}: #{e.class}: #{e.message}"
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
