# frozen_string_literal: true

require "rails_helper"

# Audit finding F4-03: allocate_ip/release_ip called Registry.for_node(nil,
# region:) which dereferenced nil.account and raised NoMethodError on every
# invocation — the standalone elastic-IP capability had never worked. The fix
# resolves the adapter from (region, account) like VolumeManagementService;
# these specs pin that lookup path so it cannot regress.
RSpec.describe System::IpManagementService do
  let(:account)    { create(:account) }
  let(:region)     { create(:system_provider_region) }
  let(:connection) { double("provider connection") }
  let(:adapter)    { instance_double("System::Providers::BaseProvider") }

  before do
    allow(System::Providers::Registry).to receive(:find_connection_for_region)
      .with(region, account).and_return(connection)
    allow(System::Providers::Registry).to receive(:for)
      .with(connection, region: region).and_return(adapter)
    allow(adapter).to receive(:supports?).and_return(true)
  end

  describe ".allocate_ip" do
    it "allocates via the adapter resolved from region + account" do
      allow(adapter).to receive(:allocate_ip)
        .and_return({ success: true, allocation_id: "eip-1", public_ip: "203.0.113.9" })

      result = described_class.allocate_ip(region: region, account: account)

      expect(result[:success]).to be(true)
      expect(result[:allocation_id]).to eq("eip-1")
      expect(result[:public_ip]).to eq("203.0.113.9")
    end

    # Audit F4-06 — local_qemu has no IP surface; the capability gate must
    # refuse structurally instead of letting NotImplementedError propagate.
    it "returns a structured error when the provider lacks IP support" do
      allow(adapter).to receive(:supports?).with(:ips).and_return(false)
      allow(adapter).to receive(:provider_type).and_return("local_qemu")
      allow(adapter).to receive(:allocate_ip)

      result = described_class.allocate_ip(region: region, account: account)

      expect(result[:success]).to be(false)
      expect(result[:error]).to match(/does not support IP/i)
      expect(adapter).not_to have_received(:allocate_ip)
    end

    it "returns an error result when no provider connection covers the region" do
      allow(System::Providers::Registry).to receive(:find_connection_for_region)
        .with(region, account).and_return(nil)

      result = described_class.allocate_ip(region: region, account: account)

      expect(result[:success]).to be(false)
      expect(result[:error]).to match(/No provider connection/)
    end

    it "returns an error result on provider failure" do
      allow(adapter).to receive(:allocate_ip)
        .and_return({ success: false, error: "quota exceeded" })

      result = described_class.allocate_ip(region: region, account: account)

      expect(result[:success]).to be(false)
      expect(result[:error]).to eq("quota exceeded")
    end
  end

  describe ".release_ip" do
    it "releases via the adapter resolved from region + account" do
      allow(adapter).to receive(:release_ip).with("eip-1").and_return({ success: true })

      result = described_class.release_ip(region: region, account: account, allocation_id: "eip-1")

      expect(result[:success]).to be(true)
    end

    it "returns an error result when no provider connection covers the region" do
      allow(System::Providers::Registry).to receive(:find_connection_for_region)
        .with(region, account).and_return(nil)

      result = described_class.release_ip(region: region, account: account, allocation_id: "eip-1")

      expect(result[:success]).to be(false)
      expect(result[:error]).to match(/No provider connection/)
    end
  end

  # F4-09 — the instance-side pair (associate/disassociate) had no coverage;
  # only the region-side pair (allocate/release) was pinned by F4-03. These
  # resolve their adapter from the INSTANCE (Registry.for_instance), a
  # different lookup path than allocate/release.
  describe "instance-side association (F4-09)" do
    let(:platform) { create(:system_node_platform, account: account) }
    let(:template) { create(:system_node_template, account: account, node_platform: platform) }
    let(:node)     { create(:system_node, account: account, node_template: template) }
    let(:instance) do
      create(:system_node_instance, node: node, status: "running",
             cloud_instance_id: "vm-9", public_ip_address: nil)
    end

    before do
      allow(System::Providers::Registry).to receive(:for_instance)
        .with(instance).and_return(adapter)
    end

    describe ".associate_public_ip" do
      it "associates and persists the IP + allocation ids onto the instance" do
        allow(adapter).to receive(:associate_ip)
          .with("vm-9", allocation_id: nil)
          .and_return({ success: true, public_ip: "203.0.113.7",
                        allocation_id: "eip-7", association_id: "assoc-7" })

        result = described_class.associate_public_ip(instance: instance)

        expect(result[:success]).to be(true)
        instance.reload
        expect(instance.public_ip_address).to eq("203.0.113.7")
        expect(instance.config["ip_allocation_id"]).to eq("eip-7")
        expect(instance.config["ip_association_id"]).to eq("assoc-7")
      end

      it "short-circuits when the instance already has a public IP" do
        instance.update!(public_ip_address: "198.51.100.1")
        allow(adapter).to receive(:associate_ip)

        result = described_class.associate_public_ip(instance: instance)

        expect(result[:success]).to be(true)
        expect(result[:message]).to match(/already associated/i)
        expect(adapter).not_to have_received(:associate_ip)
      end

      it "errors when the instance has no cloud instance ID" do
        # `provider_identity: false` is the factory's opt-out for the
        # identity-less shape. Omitting cloud_instance_id (or overriding it
        # to nil) does NOT produce it — the factory backfills a generated id
        # for cloud/dynamic varieties, which would carry execution past this
        # guard and into Providers::Registry.
        bare = create(:system_node_instance, node: node, status: "running", provider_identity: false)

        result = described_class.associate_public_ip(instance: bare)

        expect(result[:success]).to be(false)
        expect(result[:error]).to match(/no cloud instance ID/i)
      end

      it "propagates a provider failure without mutating the instance" do
        allow(adapter).to receive(:associate_ip)
          .and_return({ success: false, error: "address limit exceeded" })

        result = described_class.associate_public_ip(instance: instance)

        expect(result[:success]).to be(false)
        expect(result[:error]).to eq("address limit exceeded")
        expect(instance.reload.public_ip_address).to be_nil
      end
    end

    describe ".disassociate_public_ip" do
      before do
        instance.update!(
          public_ip_address: "203.0.113.7",
          config: instance.config.merge("ip_allocation_id" => "eip-7",
                                        "ip_association_id" => "assoc-7")
        )
      end

      it "disassociates, releases, and clears the instance's IP state" do
        allow(adapter).to receive(:disassociate_ip).with("assoc-7").and_return({ success: true })
        allow(adapter).to receive(:release_ip).with("eip-7").and_return({ success: true })

        result = described_class.disassociate_public_ip(instance: instance)

        expect(result[:success]).to be(true)
        instance.reload
        expect(instance.public_ip_address).to be_nil
        expect(instance.config).not_to have_key("ip_allocation_id")
        expect(instance.config).not_to have_key("ip_association_id")
      end

      it "skips the release when release: false" do
        allow(adapter).to receive(:disassociate_ip).and_return({ success: true })
        allow(adapter).to receive(:release_ip)

        result = described_class.disassociate_public_ip(instance: instance, release: false)

        expect(result[:success]).to be(true)
        expect(adapter).not_to have_received(:release_ip)
      end

      it "returns ok when there is no public IP to disassociate" do
        bare = create(:system_node_instance, node: node, status: "running")

        result = described_class.disassociate_public_ip(instance: bare)

        expect(result[:success]).to be(true)
        expect(result[:message]).to match(/no public ip/i)
      end

      it "propagates a disassociate failure and leaves the IP state intact" do
        allow(adapter).to receive(:disassociate_ip)
          .and_return({ success: false, error: "association busy" })

        result = described_class.disassociate_public_ip(instance: instance)

        expect(result[:success]).to be(false)
        expect(result[:error]).to eq("association busy")
        expect(instance.reload.public_ip_address).to eq("203.0.113.7")
      end

      # Audit F5-08 — release failures are deliberately non-fatal: the IP
      # is already disassociated, so clearing the local allocation state
      # must proceed (the warn log is the operator's signal to chase the
      # billable orphan with the provider). The release must fire exactly
      # once — a retry loop here could double-release a reallocated IP.
      it "clears the allocation even when the provider release errors mid-way" do
        allow(adapter).to receive(:disassociate_ip).with("assoc-7").and_return({ success: true })
        allow(adapter).to receive(:release_ip).with("eip-7")
          .and_return({ success: false, error: "still attached upstream" })

        result = described_class.disassociate_public_ip(instance: instance, release: true)

        expect(result[:success]).to be(true)
        expect(adapter).to have_received(:release_ip).exactly(:once)
        instance.reload
        expect(instance.public_ip_address).to be_nil
        expect(instance.config).not_to have_key("ip_allocation_id")
        expect(instance.config).not_to have_key("ip_association_id")
      end
    end
  end
end
