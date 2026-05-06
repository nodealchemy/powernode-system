# frozen_string_literal: true

# Normalizes column comments on system_node_platforms to use generic
# placeholder hostnames (RFC 2606 example.com) rather than environment-
# specific references. Forward-only fix for databases that already
# applied the prior create-columns migration.
class NormalizeDiskImagePublicationComments < ActiveRecord::Migration[8.1]
  def up
    change_column_comment :system_node_platforms, :cosign_identity_regexp,
                          "Sigstore Fulcio identity regexp the publication processor will accept (e.g. 'https://registry.example.com/powernode/.+')"

    change_column_comment :system_node_platforms, :cosign_issuer_regexp,
                          "Sigstore Fulcio OIDC issuer regexp (e.g. 'https://registry.example.com')"

    change_column_comment :system_node_platforms, :disk_image_oci_ref,
                          "Last-published OCI reference (e.g. registry.example.com/powernode/disk-images/ubuntu-24.04-rpi4:abc123)"
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Column-comment normalization is forward-only"
  end
end
