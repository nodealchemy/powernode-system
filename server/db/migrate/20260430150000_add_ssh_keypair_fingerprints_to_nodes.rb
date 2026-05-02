# frozen_string_literal: true

# Adds SSH-key fingerprint columns and a key-type discriminator to system_nodes.
# Required by Golden Eclipse M0.H — Node SSH keypair auto-generation port from
# legacy ~/Drive/Projects/powernode-server/app/models/node.rb (initialize_ssh_keys + fingerprints).
# Default ssh_key_type is 'ed25519' (modern); 'rsa' is supported via NodeTemplate.config['legacy_rsa_keys'].
class AddSshKeypairFingerprintsToNodes < ActiveRecord::Migration[8.0]
  def change
    change_table :system_nodes, bulk: true do |t|
      t.string :ssh_key_fingerprint
      t.string :ssh_host_key_fingerprint
      t.string :ssh_key_type, null: false, default: "ed25519"
    end

    add_index :system_nodes, :ssh_key_fingerprint
    add_index :system_nodes, :ssh_host_key_fingerprint
  end
end
