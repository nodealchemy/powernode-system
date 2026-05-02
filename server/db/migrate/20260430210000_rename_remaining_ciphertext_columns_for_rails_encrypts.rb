# frozen_string_literal: true

# Golden Eclipse M0 polish — fix the remaining Rails-encrypts column-name
# mismatches in the System extension. Same bug pattern as M0.H:
# `encrypts :foo` (Rails 7+) expects column `foo`, NOT `foo_ciphertext`
# (the attr_encrypted gem convention). Three additional models were affected:
#
# - System::ProviderConnection#access_key   (cloud provider access keys)
# - System::ProviderConnection#secret_key   (cloud provider secrets)
# - System::NodeInstance#key                (instance-specific key material)
#
# Same as M0.H: no production data is at risk because the broken encrypts
# pipeline silently no-op'd writes against the unbacked virtual attribute.
class RenameRemainingCiphertextColumnsForRailsEncrypts < ActiveRecord::Migration[8.0]
  def change
    rename_column :system_provider_connections, :access_key_ciphertext, :access_key
    rename_column :system_provider_connections, :secret_key_ciphertext, :secret_key
    rename_column :system_node_instances,       :key_ciphertext,        :key
  end
end
