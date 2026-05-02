# frozen_string_literal: true

require "rails_helper"

# Golden Eclipse Block B — SystemBootstrapService composes
# BootstrapToken.issue! + NetbootService.render_ipxe_script.
RSpec.describe System::BootstrapService do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform) }
  let(:node)     { create(:system_node, account: account, node_template: template) }
  let(:instance) { create(:system_node_instance, :running, node: node) }

  describe ".render_for_instance" do
    it "issues a token + renders an iPXE script" do
      expect {
        result = described_class.render_for_instance(instance: instance)
        expect(result.ok?).to be true
        expect(result.script).to include("#!ipxe")
        expect(result.script).to include("powernode.bootstrap_token=")
        expect(result.script).to include("powernode.instance_uuid=#{instance.id}")
        expect(result.token_id).to be_present
      }.to change(System::BootstrapToken, :count).by(1)
    end

    it "uses the provided image_base override" do
      result = described_class.render_for_instance(
        instance: instance,
        image_base: "https://custom.example/images"
      )
      expect(result.script).to include("kernel https://custom.example/images")
    end

    it "rejects non-NodeInstance arguments" do
      result = described_class.render_for_instance(instance: "not-an-instance")
      expect(result.ok?).to be false
      expect(result.error).to match(/instance: required/)
    end

    it "uses ca_pem_url when POWERNODE_CA_PEM_URL is set" do
      original = ENV["POWERNODE_CA_PEM_URL"]
      ENV["POWERNODE_CA_PEM_URL"] = "https://ca.example/cert.pem"
      begin
        result = described_class.render_for_instance(instance: instance)
        expect(result.script).to include("powernode.ca_url=https://ca.example/cert.pem")
        expect(result.script).not_to include("powernode.ca=-----")
      ensure
        ENV["POWERNODE_CA_PEM_URL"] = original
      end
    end

    it "honors a custom ttl" do
      result = described_class.render_for_instance(instance: instance, ttl: 10.minutes)
      token = System::BootstrapToken.find(result.token_id)
      expect(token.expires_at).to be_within(30.seconds).of(10.minutes.from_now)
    end
  end
end
