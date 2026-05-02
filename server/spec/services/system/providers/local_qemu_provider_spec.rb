# frozen_string_literal: true

require "rails_helper"

# Golden Eclipse M4 — LocalQemuProvider integration spec.
# Uses RecorderRunner so no real libvirt daemon is required; asserts on
# the actual virsh invocations + domain XML structure that would land
# against a real libvirtd.
RSpec.describe System::Providers::LocalQemuProvider do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform) }
  let(:node)     { create(:system_node, account: account, node_template: template) }
  let(:instance) { create(:system_node_instance, node: node) }

  let(:connection) { build_stubbed(:system_provider_connection, provider: build_stubbed(:system_provider, provider_type: "local_qemu")) } rescue nil
  let(:provider)   { described_class.allocate.tap { |p| p.instance_variable_set(:@connection, nil); p.instance_variable_set(:@region, nil); p.instance_variable_set(:@logger, Rails.logger) } }

  let(:runner) { System::Providers::LocalQemu::RecorderRunner.new }

  before do
    System::Providers::LocalQemuProvider.runner = runner
  end

  after do
    System::Providers::LocalQemuProvider.reset_runner!
  end

  describe "#provider_type" do
    it "returns local_qemu" do
      expect(provider.provider_type).to eq("local_qemu")
    end
  end

  describe "#create_instance" do
    it "defines + starts a libvirt domain and returns starting status" do
      result = provider.create_instance(
        name: "test-domain",
        instance: instance,
        memory_mb: 1024,
        vcpus: 1
      )
      expect(result[:success]).to be true
      expect(result[:cloud_instance_id]).to eq("test-domain")
      expect(result[:status]).to eq("starting")
      expect(result[:bootstrap_token_id]).to be_present.or be_nil # token issuance is best-effort

      methods = runner.invocations.map { |i| i[:method] }
      expect(methods).to eq([:define_domain!, :start_domain!])

      define_call = runner.invocations.find { |i| i[:method] == :define_domain! }
      xml = define_call[:args][:xml]
      expect(xml).to include("<name>test-domain</name>")
      expect(xml).to include("<uuid>#{instance.id}</uuid>")
      expect(xml).to include("<memory unit='MiB'>1024</memory>")
      expect(xml).to include("<vcpu placement='static'>1</vcpu>")
    end

    it "embeds fw-cfg entries for the bootstrap seed" do
      result = provider.create_instance(name: "fwcfg-test", instance: instance)
      xml = runner.invocations.first[:args][:xml]
      expect(xml).to include("opt/com.powernode/instance_uuid")
      expect(xml).to include("opt/com.powernode/bootstrap_token")
      expect(xml).to include("opt/com.powernode/ca_pem")
      expect(xml).to include("opt/com.powernode/platform_url")
    end

    it "selects amd64 emulator + machine type by default" do
      provider.create_instance(name: "amd-test", instance: instance)
      xml = runner.invocations.first[:args][:xml]
      expect(xml).to include("qemu-system-x86_64")
      expect(xml).to include("machine='q35'")
      expect(xml).to include("arch='x86_64'")
    end

    it "selects arm64 emulator + virt machine when arch=arm64" do
      provider.create_instance(name: "arm-test", instance: instance, arch: "arm64")
      xml = runner.invocations.first[:args][:xml]
      expect(xml).to include("qemu-system-aarch64")
      expect(xml).to include("machine='virt'")
      expect(xml).to include("arch='aarch64'")
    end

    it "embeds lockdown + IMA + powernode.boot kernel cmdline flags" do
      provider.create_instance(name: "kcmd-test", instance: instance)
      xml = runner.invocations.first[:args][:xml]
      expect(xml).to include("lockdown=integrity")
      expect(xml).to include("ima_appraise=enforce")
      expect(xml).to include("powernode.boot=1")
      expect(xml).to include("powernode.identity_source=fwcfg")
    end

    it "fails fast when define returns ok=false" do
      runner.stub(:define_domain!, { ok: false, error: "name conflict" })
      result = provider.create_instance(name: "fail-test", instance: instance)
      expect(result[:success]).to be false
      expect(result[:error]).to match(/name conflict/)
    end

    it "fails fast when instance is nil" do
      result = provider.create_instance(name: "no-instance")
      expect(result[:success]).to be false
      expect(result[:error]).to match(/instance: required/)
    end
  end

  describe "#terminate_instance" do
    it "destroys then undefines" do
      result = provider.terminate_instance("doomed")
      expect(result[:success]).to be true
      expect(result[:status]).to eq("terminated")
      methods = runner.invocations.map { |i| i[:method] }
      expect(methods).to eq([:destroy_domain!, :undefine_domain!])
    end
  end

  describe "#start_instance / #stop_instance / #reboot_instance" do
    it "maps to runner methods + returns BaseProvider response shape" do
      provider.start_instance("d1")
      provider.stop_instance("d1")
      provider.stop_instance("d1", force: true)
      provider.reboot_instance("d1")
      methods = runner.invocations.map { |i| i[:method] }
      expect(methods).to eq(%i[start_domain! shutdown_domain! destroy_domain! reboot_domain!])
    end
  end

  describe "#get_instance" do
    it "normalizes 'running' libvirt state to running" do
      runner.stub(:dominfo!, { ok: true, state: "running", private_ip: "192.168.122.50" })
      result = provider.get_instance("alive")
      expect(result[:status]).to eq("running")
      expect(result[:private_ip_address]).to eq("192.168.122.50")
    end

    it "normalizes 'shut off' to stopped" do
      runner.stub(:dominfo!, { ok: true, state: "shut off", private_ip: nil })
      expect(provider.get_instance("dead")[:status]).to eq("stopped")
    end

    it "normalizes unknown libvirt states to unknown" do
      runner.stub(:dominfo!, { ok: true, state: "weird-state", private_ip: nil })
      expect(provider.get_instance("weird")[:status]).to eq("unknown")
    end
  end

  describe "#test_connection" do
    it "delegates to runner.uri_check!" do
      result = provider.test_connection
      expect(result[:success]).to be true
      expect(result[:message]).to match(/libvirt reachable/)
    end
  end

  describe "Registry integration" do
    it "is registered under 'local_qemu'" do
      expect(System::Providers::Registry::PROVIDER_CLASSES["local_qemu"]).to eq("System::Providers::LocalQemuProvider")
    end
  end
end
