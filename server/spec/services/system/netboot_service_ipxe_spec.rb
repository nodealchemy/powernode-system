# frozen_string_literal: true

require "rails_helper"

# Golden Eclipse M3 — iPXE chainload rendering via NetbootService.
RSpec.describe System::NetbootService, ".render_ipxe_script" do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform) }
  let(:node)     { create(:system_node, account: account, node_template: template) }
  let(:instance) { create(:system_node_instance, :running, node: node) }

  let(:ca_pem) { self_signed_ca_pem }
  let(:pin)    { System::ProvisioningDocument.fingerprint_for(ca_pem) }

  before { stub_enroll_settings(ca: ca_pem, url: "https://platform.example.test") }

  describe "with valid arguments" do
    it "renders the iPXE template with all variables substituted" do
      script = described_class.render_ipxe_script(
        instance: instance,
        bootstrap_token: "tok-abc-1234",
        image_base: "https://platform.example/.well-known/powernode/images"
      )
      expect(script).to include("#!ipxe")
      expect(script).to include("powernode.bootstrap_token=tok-abc-1234")
      expect(script).to include("powernode.instance_uuid=#{instance.id}")
      expect(script).not_to include("powernode.ca=")
      expect(script).not_to include("BEGIN CERTIFICATE")
      expect(script).to include("https://platform.example/.well-known/powernode/images")
      expect(script).to include("kernel https://platform.example")
      expect(script).to include("initrd https://platform.example")
      expect(script).to include("set arch ${buildarch}")
    end
  end

  describe "CA pin, platform_url and CA fetch pointer" do
    def render(**kw)
      described_class.render_ipxe_script(instance: instance, bootstrap_token: "tok-2",
                                         image_base: "https://example", **kw)
    end

    it "emits platform_url" do
      expect(render).to include("powernode.platform_url=https://platform.example.test ")
    end

    it "emits ca_fingerprint computed from the configured CA" do
      expect(render).to include("powernode.ca_fingerprint=#{pin} ")
      expect(pin).to match(/\Asha256:[0-9a-f]{64}\z/)
    end

    it "defaults ca_pem_url to the public netboot ca.pem route" do
      expect(render).to include("powernode.ca_pem_url=https://platform.example.test/api/v1/system/netboot/ca.pem ")
    end

    it "refuses without a CA" do
      stub_enroll_settings(ca: nil)
      expect { render }.to raise_error(System::ProvisioningDocument::RenderError, /no CA certificate/)
    end

    it "refuses without a platform_url" do
      stub_enroll_settings(ca: ca_pem, url: nil)
      expect { render }.to raise_error(System::NetbootService::NetbootError, /platform_url/)
    end

    it "refuses a non-https platform_url" do
      expect { render(platform_url: "http://platform.example.test") }
        .to raise_error(System::ProvisioningDocument::RenderError, /https/)
    end

    it "refuses a platform_url that could inject cmdline arguments" do
      expect { render(platform_url: "https://p.example.test powernode.x=1") }
        .to raise_error(System::ProvisioningDocument::RenderError)
    end

    [
      "https://ca.example/a b.pem",
      "https://ca.example/a$b.pem",
      "https://ca.example/a\"b.pem",
      "https://ca.example/a'b.pem",
      "https://ca.example/a\nb.pem",
      "file:///etc/passwd",
      "ftp://ca.example/ca.pem"
    ].each do |bad|
      it "refuses ca_pem_url #{bad.inspect}" do
        expect { render(ca_pem_url: bad) }.to raise_error(System::NetbootService::NetbootError, /ca_pem_url/)
      end
    end

    it "allows a plain http ca_pem_url (the pin authenticates the bytes)" do
      expect(render(ca_pem_url: "http://ca.example/ca.pem")).to include("powernode.ca_pem_url=http://ca.example/ca.pem ")
    end

    it "embeds an explicit ca_pem_url override" do
      script = render(ca_pem_url: "https://example/.well-known/powernode-ca.pem")
      expect(script).to include("powernode.ca_pem_url=https://example/.well-known/powernode-ca.pem")
      expect(script).not_to include("powernode.ca_url=")
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
        image_base: "https://x"
      )
      expect(script).to include("lockdown=integrity")
      expect(script).to include("ima_appraise=enforce")
      expect(script).to include("powernode.boot=1")
    end
  end
end
