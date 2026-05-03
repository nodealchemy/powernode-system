# frozen_string_literal: true

# Permissions for NodeInstance-as-Agent peer registration + remote
# task delegation:
#   - system.peers.read     — list/show NodeInstancePeer
#   - system.peers.activate — flip enabled true (operator activation gate)
#   - system.peers.execute  — delegate a remote task to a peer
#   - system.peer.announce  — peer-side endpoint (mTLS-authenticated instance JWT)
#
# Reference: comprehensive stabilization sweep P6; Golden Eclipse F-3.
class SeedPeerPermissions < ActiveRecord::Migration[8.1]
  PERMISSIONS = {
    "system.peers.read" => {
      resource: "system.peers", action: "read",
      description: "List and view registered NodeInstance peers"
    },
    "system.peers.activate" => {
      resource: "system.peers", action: "activate",
      description: "Activate / deactivate a NodeInstance peer for remote execution"
    },
    "system.peers.execute" => {
      resource: "system.peers", action: "execute",
      description: "Delegate a remote task to a NodeInstance peer"
    },
    "system.peer.announce" => {
      resource: "system.peer", action: "announce",
      description: "NodeInstance-side endpoint — agent self-announces via mTLS"
    }
  }.freeze

  def up
    return unless table_exists?(:permissions)

    PERMISSIONS.each do |name, attrs|
      ::Permission.find_or_create_by!(name: name) do |p|
        p.resource    = attrs[:resource]
        p.action      = attrs[:action]
        p.description = attrs[:description]
        p.category    = "resource" if p.respond_to?(:category=)
      end
    end
  end

  def down
    return unless table_exists?(:permissions)
    ::Permission.where(name: PERMISSIONS.keys).destroy_all
  end
end
