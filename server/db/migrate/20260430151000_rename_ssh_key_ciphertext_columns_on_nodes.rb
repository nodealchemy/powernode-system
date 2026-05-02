# frozen_string_literal: true

# Fixes a latent platform bug: System::Node declared `encrypts :ssh_key` (Rails 7+
# Active Record Encryption) but the schema had `ssh_key_ciphertext` columns
# (the legacy `attr_encrypted` gem convention). Rails-encrypts expected the
# columns to be `ssh_key` / `ssh_host_key` directly. The mismatch meant writes
# silently no-op'd against an unbacked virtual attribute and reloads returned
# nil for the encrypted fields.
#
# Discovered while implementing Golden Eclipse M0.H (Node SSH key auto-generation
# port). No production data is at risk because the broken encryption layer has
# always written nothing.
class RenameSshKeyCiphertextColumnsOnNodes < ActiveRecord::Migration[8.0]
  def change
    rename_column :system_nodes, :ssh_key_ciphertext,      :ssh_key
    rename_column :system_nodes, :ssh_host_key_ciphertext, :ssh_host_key
  end
end
