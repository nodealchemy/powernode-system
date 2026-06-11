# frozen_string_literal: true

require "rails_helper"

# Audit F5-07 — PlatformDeploymentOrchestrator (the engine behind
# system_deploy_platform, the deployments controller, and the
# storage-migration flow) had zero spec references; the only indirect
# coverage stubbed ProvisioningService at the request level, leaving
# deploy_federated!, the resolver error paths, and volume auto-selection
# unexercised.
RSpec.describe System::PlatformDeploymentOrchestrator do
  let(:account)  { create(:account) }
  let(:user)     { create(:user, account: account) }
  let(:template) { create(:system_node_template, account: account, name: "powernode-base") }
  let(:service)  { described_class.new(account: account, initiated_by_user: user) }

  describe "#deploy! common validation" do
    it "returns an error Result for an unknown mode" do
      result = service.deploy!(mode: "sideways", params: { name: "p", template_slug: "x" })

      expect(result.ok?).to be false
      expect(result.error).to match(/Unknown mode "sideways"/)
    end

    it "returns an error Result when template_slug is missing" do
      result = service.deploy!(mode: "standalone", params: { name: "p" })

      expect(result.ok?).to be false
      expect(result.error).to match(/template_slug is required/)
    end

    it "returns an error Result when name is missing" do
      result = service.deploy!(mode: "standalone", params: { template_slug: template.name })

      expect(result.ok?).to be false
      expect(result.error).to match(/name is required/)
    end
  end

  describe "#deploy_federated!" do
    let(:peer) do
      create(:system_federation_peer, account: account,
             metadata: { "provisioner_response" => { "node_instance_id" => instance.id } })
    end
    let(:node)     { create(:system_node, account: account, node_template: template) }
    let(:provider_region) { create(:system_provider_region) }
    let(:provider_instance_type) { create(:system_provider_instance_type) }
    let(:instance) do
      create(:system_node_instance, node: node, name: "spawned-child", variety: "cloud",
             status: "pending", provider_region: provider_region,
             provider_instance_type: provider_instance_type)
    end

    let(:federated_params) do
      {
        name: "child-platform",
        template_slug: template.name,
        parent_url: "https://parent.example.com",
        spawn_mode: "managed_child"
      }
    end

    it "rejects an invalid spawn_mode before touching SpawnPlatformService" do
      allow(System::SpawnPlatformService).to receive(:spawn!)

      result = service.deploy!(mode: "federated",
                               params: federated_params.merge(spawn_mode: "viral"))

      expect(result.ok?).to be false
      expect(result.error).to match(/Invalid spawn_mode "viral"/)
      expect(System::SpawnPlatformService).not_to have_received(:spawn!)
    end

    it "requires parent_url" do
      result = service.deploy!(mode: "federated",
                               params: federated_params.except(:parent_url))

      expect(result.ok?).to be false
      expect(result.error).to match(/parent_url is required/)
    end

    it "returns the spawn failure as an error Result" do
      allow(System::SpawnPlatformService).to receive(:spawn!)
        .and_return(double(ok?: false, error: "acceptance token mint failed"))

      result = service.deploy!(mode: "federated", params: federated_params)

      expect(result.ok?).to be false
      expect(result.error).to eq("acceptance token mint failed")
    end

    it "spawns via SpawnPlatformService, resolves the instance off the peer, and records the deployment" do
      spawn_result = double(
        ok?: true,
        federation_peer: peer,
        acceptance_token: "tok-abc123",
        spawn_payload: { "provisioner_response" => { "node_instance_id" => instance.id } }
      )
      allow(System::SpawnPlatformService).to receive(:spawn!).and_return(spawn_result)

      result = service.deploy!(mode: "federated", params: federated_params)

      expect(result.ok?).to be true
      expect(result.mode).to eq("federated")
      expect(result.federation_peer_id).to eq(peer.id)
      expect(result.acceptance_token).to eq("tok-abc123")
      expect(result.node_instance_id).to eq(instance.id)

      expect(System::SpawnPlatformService).to have_received(:spawn!).with(
        hash_including(
          account: account,
          spawn_mode: "managed_child",
          parent_url: "https://parent.example.com",
          initiated_by_user: user,
          token_ttl_seconds: System::SpawnPlatformService::DEFAULT_TOKEN_TTL,
          spawn_target: hash_including(template_id: template.name, name: "child-platform")
        )
      )

      deployment = System::PlatformDeployment.find(result.platform_deployment_id)
      expect(deployment.node_template_id).to eq(template.id)
      expect(deployment.service_role).to eq("api")
      expect(deployment.target_replicas).to eq(1)
      expect(deployment.metadata["initial_instance_id"]).to eq(instance.id)
      expect(deployment.metadata["deployed_by_user_id"]).to eq(user.id)
    end

    it "falls back to the peer metadata for the instance id when spawn_payload omits it" do
      spawn_result = double(ok?: true, federation_peer: peer,
                            acceptance_token: "tok", spawn_payload: nil)
      allow(System::SpawnPlatformService).to receive(:spawn!).and_return(spawn_result)

      result = service.deploy!(mode: "federated", params: federated_params)

      expect(result.ok?).to be true
      expect(result.node_instance_id).to eq(instance.id)
    end

    it "skips the deployment record when record_deployment is false" do
      spawn_result = double(ok?: true, federation_peer: peer,
                            acceptance_token: "tok", spawn_payload: nil)
      allow(System::SpawnPlatformService).to receive(:spawn!).and_return(spawn_result)

      result = service.deploy!(mode: "federated",
                               params: federated_params.merge(record_deployment: false))

      expect(result.ok?).to be true
      expect(result.platform_deployment_id).to be_nil
      expect(System::PlatformDeployment.count).to eq(0)
    end
  end

  describe "resolver error paths" do
    it "resolve_template! raises with the unknown slug in the message" do
      expect {
        service.send(:resolve_template!, "no-such-template")
      }.to raise_error(described_class::OrchestrationError, /template not found: no-such-template/)
    end

    it "resolve_template! finds by name or by id" do
      expect(service.send(:resolve_template!, template.name)).to eq(template)
      expect(service.send(:resolve_template!, template.id)).to eq(template)
    end

    it "resolve_template! never resolves another account's template" do
      other = create(:system_node_template, name: "powernode-other")

      expect {
        service.send(:resolve_template!, other.id)
      }.to raise_error(described_class::OrchestrationError, /template not found/)
    end

    it "resolve_region! raises for an unknown explicit provider_region_id" do
      node = create(:system_node, account: account, node_template: template)

      expect {
        service.send(:resolve_region!, node, { provider_region_id: "019e0000-0000-7000-8000-000000000000" })
      }.to raise_error(described_class::OrchestrationError, /provider_region not found/)
    end

    # Account#after_create_commit runs System::AccountBootstrapService,
    # which seeds a default Provider + regions for every account — so a
    # provider-less account only exists when bootstrap failed (the
    # callback rescues, account.rb). Simulate that state explicitly.
    it "resolve_region! raises when the account has no provider at all (bootstrap failed)" do
      node = create(:system_node, account: account, node_template: template)
      System::Provider.where(account_id: account.id).destroy_all

      expect {
        service.send(:resolve_region!, node, {})
      }.to raise_error(described_class::OrchestrationError, /no provider available for account/)
    end

    it "resolve_region! raises when the only provider has no regions" do
      node = create(:system_node, account: account, node_template: template)
      System::Provider.where(account_id: account.id).destroy_all
      create(:system_provider, account: account, name: "regionless")

      expect {
        service.send(:resolve_region!, node, {})
      }.to raise_error(described_class::OrchestrationError, /no provider_region for provider regionless/)
    end

    it "resolve_instance_type! raises for an unknown explicit id" do
      region = create(:system_provider_region)

      expect {
        service.send(:resolve_instance_type!, region,
                     { provider_instance_type_id: "019e0000-0000-7000-8000-000000000001" })
      }.to raise_error(described_class::OrchestrationError, /provider_instance_type not found/)
    end

    it "resolve_instance_type! raises when the provider has no instance types" do
      region = create(:system_provider_region)

      expect {
        service.send(:resolve_instance_type!, region, {})
      }.to raise_error(described_class::OrchestrationError, /no provider_instance_type for provider/)
    end
  end

  describe "#attach_storage_volume!" do
    let(:node) { create(:system_node, account: account, node_template: template) }
    let(:provider_region) { create(:system_provider_region) }
    let(:provider_instance_type) { create(:system_provider_instance_type) }
    let(:instance) do
      create(:system_node_instance, node: node, name: "deploy-target", variety: "cloud",
             status: "running", provider_region: provider_region,
             provider_instance_type: provider_instance_type)
    end

    it "returns nil for a stateless role with no explicit volume" do
      create(:system_provider_volume, account: account, size_gb: 100)

      expect(service.send(:attach_storage_volume!, instance, { name: "p", service_role: "api" }))
        .to be_nil
    end

    it "returns nil when the operator opts out via skip_volume" do
      volume = create(:system_provider_volume, account: account, size_gb: 100)

      binding = service.send(:attach_storage_volume!, instance,
                             { name: "p", volume_id: volume.id, skip_volume: true })

      expect(binding).to be_nil
      expect(volume.reload.status).to eq("available")
    end

    it "reports an unattachable explicit volume without raising" do
      volume = create(:system_provider_volume, :attached, account: account,
                      node_instance_id: instance.id, device_name: "/dev/vdb")

      binding = service.send(:attach_storage_volume!, instance,
                             { name: "p", volume_id: volume.id })

      expect(binding[:error]).to eq("volume_not_attachable")
      expect(binding[:volume_id]).to eq(volume.id)
    end

    it "auto-selects the smallest adequate available volume for a stateful role" do
      too_small = create(:system_provider_volume, account: account, size_gb: 10)
      fits      = create(:system_provider_volume, account: account, size_gb: 50)
      oversized = create(:system_provider_volume, account: account, size_gb: 500)

      binding = service.send(:attach_storage_volume!, instance,
                             { name: "pg-deploy", service_role: "postgres" })

      # postgres recommends 50GB (StorageRecommendations::DEFAULTS) — the
      # 50GB volume wins over the 500GB one; the 10GB one never qualifies.
      expect(binding[:volume_id]).to eq(fits.id)
      expect(binding[:role]).to eq("postgres")
      expect(binding[:mount_point]).to eq("/var/lib/postgresql")
      expect(binding[:transport]).to eq("block")
      expect(binding[:device_name]).to eq("/dev/vdb")

      expect(fits.reload.status).to eq("in-use")
      expect(fits.node_instance_id).to eq(instance.id)
      expect(too_small.reload.status).to eq("available")
      expect(oversized.reload.status).to eq("available")

      expect(instance.reload.config.dig("storage_volume", "volume_id")).to eq(fits.id)
    end

    it "skips the next /dev/vd letter already taken on the instance" do
      create(:system_provider_volume, :attached, account: account,
             node_instance_id: instance.id, device_name: "/dev/vdb")
      create(:system_provider_volume, :attached, account: account,
             node_instance_id: instance.id, device_name: "/dev/vdc")

      expect(service.send(:next_device_name_for, instance)).to eq("/dev/vdd")
    end

    it "treats NFS volumes as shared pools — no status flip, no device name" do
      nfs_type = create(:system_provider_volume_type, volume_type: "nfs")
      volume = create(:system_provider_volume, account: account, size_gb: 100,
                      volume_type: nfs_type,
                      config: { "nfs" => { "server" => "10.0.0.5", "export" => "/srv/pool" } })

      binding = service.send(:attach_storage_volume!, instance,
                             { name: "pg-deploy", volume_id: volume.id, service_role: "postgres" })

      expect(binding[:transport]).to eq("nfs")
      expect(binding[:device_name]).to be_nil
      expect(binding[:subpath]).to be_present
      expect(binding["nfs"]["server"]).to eq("10.0.0.5")
      # Pool stays available for other consumers — the binding lives on
      # the instance config, not the ProviderVolume row.
      expect(volume.reload.status).to eq("available")
      expect(volume.node_instance_id).to be_nil
      expect(instance.reload.config.dig("storage_volume", "transport")).to eq("nfs")
    end
  end
end
