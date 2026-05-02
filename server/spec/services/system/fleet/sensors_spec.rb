# frozen_string_literal: true

require "rails_helper"

# Golden Eclipse M7.B — fleet sensors. One spec file covers all five.
RSpec.describe "System::Fleet::Sensors" do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform) }

  describe System::Fleet::Sensors::InstanceStatusSensor do
    subject(:signals) { described_class.new(account: account).sense }

    let(:node) { create(:system_node, account: account, node_template: template) }

    context "with a fresh heartbeat" do
      before do
        inst = create(:system_node_instance, :running, node: node)
        inst.update!(last_heartbeat_at: 30.seconds.ago)
      end

      it "emits no signal" do
        expect(signals).to be_empty
      end
    end

    context "with a stale heartbeat" do
      before do
        inst = create(:system_node_instance, :running, node: node)
        inst.update!(last_heartbeat_at: 10.minutes.ago)
      end

      it "emits a system.instance_silent signal" do
        expect(signals.size).to eq(1)
        s = signals.first
        expect(s[:kind]).to eq("system.instance_silent")
        expect(s[:fingerprint]).to start_with("instance_silent:")
        expect(%i[medium high critical]).to include(s[:severity])
      end
    end

    context "with no heartbeat at all" do
      before do
        inst = create(:system_node_instance, :running, node: node)
        inst.update!(last_heartbeat_at: nil)
      end

      it "emits a high-severity signal" do
        expect(signals.first[:severity]).to eq(:high)
      end
    end
  end

  describe System::Fleet::Sensors::ModuleDriftSensor do
    subject(:signals) { described_class.new(account: account).sense }

    let(:node) { create(:system_node, account: account, node_template: template) }
    let(:mod) do
      create(:system_node_module, account: account, node_platform: platform,
             category: category, variety: "subscription", name: "drift-mod")
    end
    let!(:version) do
      v = System::NodeModuleVersion.create!(
        node_module: mod, version_number: 1,
        mask: [], file_spec: [], package_spec: [], config: {},
        oci_digest: "sha256:#{'a' * 64}"
      )
      mod.update!(current_version_id: v.id)
      v
    end

    context "with no drift" do
      before do
        System::NodeModuleAssignment.create!(node: node, node_module: mod, enabled: true, priority: 0)
        instance = create(:system_node_instance, :running, node: node)
        instance.update!(running_module_digests: { mod.id => "sha256:#{'a' * 64}" })
      end

      it "emits no signal" do
        expect(signals).to be_empty
      end
    end

    context "with a missing module" do
      before do
        System::NodeModuleAssignment.create!(node: node, node_module: mod, enabled: true, priority: 0)
        create(:system_node_instance, :running, node: node, running_module_digests: {})
      end

      it "emits a system.module_drift signal" do
        s = signals.first
        expect(s[:kind]).to eq("system.module_drift")
        expect(s[:payload]["missing_count"]).to eq(1)
      end
    end
  end

  describe System::Fleet::Sensors::CertificateExpirySensor do
    subject(:signals) { described_class.new(account: account).sense }

    let(:node) { create(:system_node, account: account, node_template: template) }
    let(:instance) { create(:system_node_instance, :running, node: node) }

    context "with a freshly issued cert" do
      before do
        System::NodeCertificate.create!(
          node_instance: instance,
          serial: "abc",
          subject: "CN=test",
          not_before: Time.current,
          not_after: 60.days.from_now,
          pem_chain: "fake"
        )
      end

      it "emits no signal" do
        expect(signals).to be_empty
      end
    end

    context "with a cert expiring within the urgent window" do
      before do
        System::NodeCertificate.create!(
          node_instance: instance,
          serial: "abc",
          subject: "CN=test",
          not_before: 89.days.ago,
          not_after: 6.hours.from_now,
          pem_chain: "fake"
        )
      end

      it "emits a high-severity system.cert_expiring signal" do
        s = signals.first
        expect(s[:kind]).to eq("system.cert_expiring")
        expect(s[:severity]).to eq(:high)
      end
    end

    context "with a revoked cert" do
      before do
        System::NodeCertificate.create!(
          node_instance: instance,
          serial: "abc", subject: "CN=test",
          not_before: 1.day.ago, not_after: 6.hours.from_now,
          pem_chain: "fake", revoked_at: 30.minutes.ago
        )
      end

      it "is excluded" do
        expect(signals).to be_empty
      end
    end
  end

  describe System::Fleet::Sensors::ModulePromotionSensor do
    subject(:signals) { described_class.new(account: account).sense }

    let(:mod) do
      create(:system_node_module, account: account, node_platform: platform,
             category: category, variety: "subscription", name: "ready-mod")
    end

    context "with a staging version that doesn't meet criteria" do
      before do
        System::NodeModuleVersion.create!(
          node_module: mod, version_number: 1,
          mask: [], file_spec: [], package_spec: [], config: {},
          oci_digest: "sha256:#{'b' * 64}",
          promotion_state: "staging"
        )
      end

      it "emits no signal" do
        expect(signals).to be_empty
      end
    end
  end

  describe System::Fleet::Sensors::ConfigDriftSensor do
    subject(:signals) { described_class.new(account: account).sense }

    let(:node) { create(:system_node, account: account, node_template: template) }
    let(:mod) do
      create(:system_node_module, account: account, node_platform: platform,
             category: category, variety: "subscription", name: "cd-mod")
    end

    context "with an assignment older than the stale threshold and no Task" do
      before do
        asgn = System::NodeModuleAssignment.create!(node: node, node_module: mod, enabled: true, priority: 0)
        asgn.update_columns(updated_at: 30.minutes.ago)
      end

      it "emits a system.config_drift signal" do
        s = signals.first
        expect(s[:kind]).to eq("system.config_drift")
      end
    end

    context "with an assignment too new (within threshold)" do
      before do
        System::NodeModuleAssignment.create!(node: node, node_module: mod, enabled: true, priority: 0)
      end

      it "emits no signal" do
        expect(signals).to be_empty
      end
    end
  end
end
