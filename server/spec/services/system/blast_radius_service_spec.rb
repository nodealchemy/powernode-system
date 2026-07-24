# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::BlastRadiusService, type: :service do
  let(:account) { create(:account) }
  let(:service) { described_class.new(account: account) }

  describe "resolving by System::Node#name" do
    it "finds the node's live instances and reports direct FK dependents" do
      node = create(:system_node, account: account, name: "ops-hub")
      instance = create(:system_node_instance, node: node, status: "error")
      storage = create(:file_storage, account: account, node_mount_capable: true)
      create(:sdwan_peer, account: account, node_instance: instance)
      create(:system_storage_assignment, account: account, node_instance: instance, file_storage_id: storage.id)

      result = service.trace("ops-hub")

      expect(result[:success]).to be true
      expect(result[:target][:kind]).to eq("node")
      expect(result[:target][:matched_via]).to include("System::Node#name")
      expect(result[:target][:instance_ids]).to contain_exactly(instance.id)
      expect(result[:dependents]["sdwan_peers"][:count]).to eq(1)
      expect(result[:dependents]["storage_assignments"][:count]).to eq(1)
      expect(result[:total_dependents]).to be >= 2
      expect(result[:dns][:modeled]).to be false
    end

    it "is case-insensitive" do
      node = create(:system_node, account: account, name: "Ops-Hub")
      create(:system_node_instance, node: node)

      result = service.trace("ops-hub")

      expect(result[:success]).to be true
      expect(result[:target][:node][:id]).to eq(node.id)
    end

    it "falls back to the most recent instance when every instance under the node is terminated" do
      node = create(:system_node, account: account, name: "ops-hub")
      older = create(:system_node_instance, node: node, status: "terminated", created_at: 2.days.ago)
      newer = create(:system_node_instance, node: node, status: "terminated", created_at: 1.hour.ago)

      result = service.trace("ops-hub")

      expect(result[:target][:instance_ids]).to contain_exactly(newer.id)
      expect(result[:target][:historical_instance_count]).to eq(2)
      expect(result[:caveats]).not_to be_empty
      expect(older.id).not_to eq(newer.id) # sanity on fixture setup
    end
  end

  describe "resolving by System::NodeInstance#name" do
    it "resolves directly to that instance" do
      node = create(:system_node, account: account)
      instance = create(:system_node_instance, node: node, name: "custom-instance-handle")

      result = service.trace("custom-instance-handle")

      expect(result[:success]).to be true
      expect(result[:target][:kind]).to eq("node_instance")
      expect(result[:target][:instance_ids]).to contain_exactly(instance.id)
    end
  end

  describe "resolving by provider cluster-node token (Proxmox-style cloud_instance_id prefix)" do
    it "matches the leading path segment and excludes terminated instances from the live set" do
      node = create(:system_node, account: account, name: "ops-hub")
      live = create(:system_node_instance, node: node, status: "error",
                                            config: { "cloud_instance_id" => "dna/qemu/104" })
      create(:system_node_instance, node: node, status: "terminated",
                                     config: { "cloud_instance_id" => "dna/qemu/102" })
      other_node = create(:system_node, account: account, name: "ci-builder-1")
      other_live = create(:system_node_instance, node: other_node, status: "running",
                                                  config: { "cloud_instance_id" => "dna/qemu/200" })

      result = service.trace("dna")

      expect(result[:success]).to be true
      expect(result[:target][:kind]).to eq("provider_host_token")
      expect(result[:target][:instance_ids]).to contain_exactly(live.id, other_live.id)
      expect(result[:target][:historical_instance_count]).to eq(3)
    end

    it "reports a historical-only match (all terminated) as an explicit caveat, not silently empty" do
      node = create(:system_node, account: account, name: "future-rna-vm")
      create(:system_node_instance, node: node, status: "terminated",
                                     config: { "cloud_instance_id" => "rna/qemu/1" })

      result = service.trace("rna")

      expect(result[:success]).to be true
      expect(result[:target][:instance_ids]).to eq([])
      expect(result[:target][:historical_instance_count]).to eq(1)
      expect(result[:caveats].join).to include("terminated")
    end

    it "does not cross-match a different token that happens to share a prefix" do
      node = create(:system_node, account: account)
      create(:system_node_instance, node: node, status: "running",
                                     config: { "cloud_instance_id" => "dna2/qemu/1" })

      result = service.trace("dna")

      expect(result[:success]).to be false
      expect(result[:error]).to include("dna")
    end
  end

  describe "not found" do
    it "returns an error with fuzzy candidates instead of guessing" do
      create(:system_node, account: account, name: "dev-cell-pool-member")

      result = service.trace("dev-cell")

      expect(result[:success]).to be false
      expect(result[:fuzzy_candidates][:node_names]).to include("dev-cell-pool-member")
    end
  end

  describe "SDWAN 2-hop traversal: peer -> VirtualIp -> Service" do
    it "surfaces the VIP and the Service backed by it when this node's peer holds the VIP" do
      node = create(:system_node, account: account, name: "ops-hub")
      instance = create(:system_node_instance, node: node)
      network = create(:sdwan_network, account: account)
      peer = create(:sdwan_peer, account: account, network: network, node_instance: instance)
      vip = create(:sdwan_virtual_ip, network: network, account: account, holder_peer_ids: [ peer.id ])
      exposed_service = create(:sdwan_service, account: account, backend_vip_id: vip.id)
      create(:sdwan_service, account: account) # unrelated service — must not appear

      result = service.trace("ops-hub")

      expect(result[:dependents]["sdwan_virtual_ips"][:ids]).to contain_exactly(vip.id)
      expect(result[:dependents]["sdwan_services"][:ids]).to contain_exactly(exposed_service.id)
    end

    it "also matches via failover_holder_peer_ids" do
      node = create(:system_node, account: account)
      instance = create(:system_node_instance, node: node)
      network = create(:sdwan_network, account: account)
      peer = create(:sdwan_peer, account: account, network: network, node_instance: instance)
      vip = create(:sdwan_virtual_ip, network: network, account: account,
                                       holder_peer_ids: [], failover_holder_peer_ids: [ peer.id ])

      result = service.trace(instance.name)

      expect(result[:dependents]["sdwan_virtual_ips"][:ids]).to contain_exactly(vip.id)
    end
  end

  describe "SDWAN port mappings — hub and target directions" do
    it "surfaces a mapping where this node's peer is the hub" do
      node = create(:system_node, account: account)
      instance = create(:system_node_instance, node: node)
      network = create(:sdwan_network, account: account)
      hub_peer = create(:sdwan_peer, :hub, account: account, network: network, node_instance: instance)
      target_peer = create(:sdwan_peer, account: account, network: network)
      mapping = create(:sdwan_port_mapping, account: account, network: network,
                                             hub_peer: hub_peer, target_peer: target_peer)

      result = service.trace(instance.name)

      expect(result[:dependents]["sdwan_port_mappings"][:ids]).to contain_exactly(mapping.id)
    end

    it "surfaces a mapping where this node's peer is the forwarding target" do
      node = create(:system_node, account: account)
      instance = create(:system_node_instance, node: node)
      network = create(:sdwan_network, account: account)
      hub_peer = create(:sdwan_peer, :hub, account: account, network: network)
      target_peer = create(:sdwan_peer, account: account, network: network, node_instance: instance)
      mapping = create(:sdwan_port_mapping, account: account, network: network,
                                             hub_peer: hub_peer, target_peer: target_peer)

      result = service.trace(instance.name)

      expect(result[:dependents]["sdwan_port_mappings"][:ids]).to contain_exactly(mapping.id)
    end
  end

  describe "cross-node storage exports (gateway_proxy / self_hosted NFS re-export)" do
    it "surfaces a StorageAssignment on ANOTHER node whose storage is exported/gatewayed through this node" do
      exporter_node = create(:system_node, account: account, name: "ops-hub")
      exporter_instance = create(:system_node_instance, node: exporter_node)
      consumer_node = create(:system_node, account: account, name: "consumer")
      consumer_instance = create(:system_node_instance, node: consumer_node)

      storage = create(:file_storage, account: account, provider_type: "nfs", deployment_shape: "gateway_proxy",
                                       node_mount_capable: true,
                                       configuration: {
                                         "mount_path" => "/mnt/x", "share_path" => "/srv/x",
                                         "re_export_path" => "/mnt/x", "server_address" => "10.0.0.5",
                                         "upstream_export_path" => "/srv/x", "upstream_source_host" => "10.0.0.5",
                                         "gateway_node_instance_id" => exporter_instance.id
                                       })
      cross_assignment = create(:system_storage_assignment, account: account,
                                                              node_instance: consumer_instance,
                                                              file_storage_id: storage.id)
      # Same-node assignment must NOT double-count into the cross-node bucket.
      create(:system_storage_assignment, account: account, node_instance: exporter_instance,
                                          file_storage_id: storage.id)

      result = service.trace("ops-hub")

      expect(result[:dependents]["cross_node_storage_exports"][:ids]).to contain_exactly(cross_assignment.id)
      expect(result[:dependents]["storage_assignments"][:count]).to eq(1) # the exporter-node one only
    end
  end

  describe "instance pool membership" do
    it "reports the pool a resolved instance belongs to, with member status breakdown" do
      node_template = create(:system_node_template, account: account)
      pool = System::InstancePool.create!(
        account: account, node_template: node_template, name: "ci-builders-amd64",
        target_size: 3, min_size: 0, max_size: 10, lifecycle_class: "ephemeral", status: "active"
      )
      node = create(:system_node, account: account, name: "ops-hub")
      instance = create(:system_node_instance, node: node, status: "running",
                                                instance_pool_id: pool.id, pool_state: "ready")
      create(:system_node_instance, account: account, status: "terminated",
                                     instance_pool_id: pool.id, pool_state: "errored")

      result = service.trace("ops-hub")

      pools = result[:dependents]["instance_pools"][:items]
      expect(pools.size).to eq(1)
      expect(pools.first[:id]).to eq(pool.id)
      expect(pools.first[:member_count]).to eq(2)
      expect(pools.first[:members_on_target]).to eq(1)
      expect(instance.instance_pool_id).to eq(pool.id) # sanity on fixture setup
    end
  end

  describe "account scoping" do
    it "does not leak another account's dependents into the resolved node's bucket" do
      node = create(:system_node, account: account, name: "ops-hub")
      instance = create(:system_node_instance, node: node)
      create(:sdwan_peer, account: account, node_instance: instance)

      other_account = create(:account)
      other_service = described_class.new(account: other_account)

      result = other_service.trace("ops-hub")

      expect(result[:success]).to be false
    end
  end
end
