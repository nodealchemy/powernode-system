# frozen_string_literal: true

# IMP-190834701b0a — the node's SSH host PUBLIC keys, as its agent reports them
# on the mTLS-authenticated heartbeat (System::SshHostKeyWriter).
# System::SshExecutionService writes them into a per-call known_hosts file so
# every SSH/SCP connection verifies the host's identity instead of trusting
# whatever answers at the recorded address.
#
# Its own column rather than a key inside `config`: several heartbeat writers
# merge into `config` on every tick, and a trust anchor should not share a
# document with telemetry. NULL means the agent has never reported a key,
# which is a different fact from an empty set and is what the connection
# policy keys on. Public keys and fingerprints only; never private material.
class AddSshHostKeysToSystemNodeInstances < ActiveRecord::Migration[8.1]
  def change
    add_column :system_node_instances, :ssh_host_keys, :jsonb
  end
end
