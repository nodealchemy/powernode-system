# frozen_string_literal: true

require "base64"
require "json"
require "net/http"
require "uri"

module System
  # Fetches the erofs layer descriptor for a published module artifact by
  # HEAD/GET-ing the OCI manifest at its oci_ref.
  #
  # Extracted verbatim from Api::V1::System::ModulePublicationsController.
  # The CI workflow only ships the artifact digest (oras push), not the
  # per-layer one the agent needs to address the blob during pull + verify
  # — this best-effort lookup backfills it.
  class OciLayerDigestFetcher
    # HEADs the OCI manifest at oci_ref and returns the descriptor
    # for the erofs layer (or nil if it can't authenticate / parse).
    # The agent uses {digest, size, media_type} during pull —
    # everything else in the manifest is informational here.
    #
    # Auth: reuses the account's Gitea PAT (the same credential the
    # operator configured for git operations); registries hosted on
    # the same Gitea instance accept that PAT as Basic-auth password
    # with any username. No new secret surface.
    def fetch_oci_layer_digest(node_module, oci_ref)
      return nil if oci_ref.blank?
      m = oci_ref.match(%r{\A([^/]+)/(.+):([^:]+)\z})
      return nil unless m
      registry, repo, tag = m[1], m[2], m[3]

      pat = node_module.account.git_provider_credentials.where(auth_type: "personal_access_token").first&.access_token
      return nil if pat.blank?

      uri = URI("https://#{registry}/v2/#{repo}/manifests/#{tag}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.open_timeout = 5
      http.read_timeout = 10
      req = Net::HTTP::Get.new(uri.path)
      req["Authorization"] = "Basic " + ::Base64.strict_encode64("ci:#{pat}")
      req["Accept"] = [
        "application/vnd.oci.image.manifest.v1+json",
        "application/vnd.docker.distribution.manifest.v2+json"
      ].join(",")
      res = http.request(req)
      return nil unless res.is_a?(Net::HTTPSuccess)

      manifest = JSON.parse(res.body)
      layers = Array(manifest["layers"])
      erofs_layer = layers.find { |l| l["mediaType"].to_s =~ /erofs/ } || layers.first
      return nil unless erofs_layer

      { digest:     erofs_layer["digest"].to_s,
        size:       erofs_layer["size"].to_i,
        media_type: erofs_layer["mediaType"].to_s }
    rescue StandardError => e
      Rails.logger.warn "[ModulePublicationsController] fetch_oci_layer_digest #{oci_ref}: #{e.class}: #{e.message}"
      nil
    end
  end
end
