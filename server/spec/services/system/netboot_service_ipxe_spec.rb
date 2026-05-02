# frozen_string_literal: true

require "rails_helper"

# Golden Eclipse M3 — iPXE chainload rendering via NetbootService.
RSpec.describe System::NetbootService, ".render_ipxe_script" do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform) }
  let(:node)     { create(:system_node, account: account, node_template: template) }
  let(:instance) { create(:system_node_instance, :running, node: node) }

  describe "with valid arguments and inline CA" do
    it "renders the iPXE template with all variables substituted" do
      script = described_class.render_ipxe_script(
        instance: instance,
        bootstrap_token: "tok-abc-1234",
        image_base: "https://platform.example/.well-known/powernode/images",
        ca_pem_inline: "-----BEGIN CERTIFICATE-----\nFAKE\n-----END CERTIFICATE-----"
      )
      expect(script).to include("#!ipxe")
      expect(script).to include("powernode.bootstrap_token=tok-abc-1234")
      expect(script).to include("powernode.instance_uuid=#{instance.id}")
      expect(script).to include("powernode.ca=-----BEGIN CERTIFICATE-----")
      expect(script).to include("https://platform.example/.well-known/powernode/images")
      expect(script).to include("kernel https://platform.example")
      expect(script).to include("initrd https://platform.example")
      expect(script).to include("set arch ${buildarch}")
    end
  end

  describe "with ca_pem_url (preferred when chain >1 cert)" do
    it "embeds powernode.ca_url instead of powernode.ca" do
      script = described_class.render_ipxe_script(
        instance: instance,
        bootstrap_token: "tok-2",
        image_base: "https://example",
        ca_pem_url: "https://example/.well-known/powernode-ca.pem"
      )
      expect(script).to include("powernode.ca_url=https://example/.well-known/powernode-ca.pem")
      expect(script).not_to include("powernode.ca=")
    end
  end

  describe "with missing arguments" do
    it "rejects empty bootstrap_token" do
      expect {
        described_class.render_ipxe_script(instance: instance, bootstrap_token: "",
                                           image_base: "https://x")
      }.to raise_error(System::NetbootService::NetbootError, /bootstrap_token required/)
    end

    it "rejects empty image_base" do
      expect {
        described_class.render_ipxe_script(instance: instance, bootstrap_token: "t", image_base: "")
      }.to raise_error(System::NetbootService::NetbootError, /image_base required/)
    end
  end

  describe "kernel cmdline lockdown flags" do
    it "always emits lockdown=integrity and ima_appraise=enforce" do
      script = described_class.render_ipxe_script(
        instance: instance, bootstrap_token: "t",
        image_base: "https://x", ca_pem_inline: "fake"
      )
      expect(script).to include("lockdown=integrity")
      expect(script).to include("ima_appraise=enforce")
      expect(script).to include("powernode.boot=1")
    end
  end
end
