# frozen_string_literal: true

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
    # The registry read (auth, Accept, layer choice, nil-on-failure) is
    # System::OciManifestClient's, shared with the native build's stale
    # re-tag guard.
    def fetch_oci_layer_digest(node_module, oci_ref)
      return nil if oci_ref.blank?

      layer = ::System::OciManifestClient.fetch(node_module: node_module, oci_ref: oci_ref)&.erofs_layer
      return nil unless layer

      { digest:     layer["digest"].to_s,
        size:       layer["size"].to_i,
        media_type: layer["mediaType"].to_s }
    end
  end
end
