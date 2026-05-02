# frozen_string_literal: true

require "rails_helper"

# Golden Eclipse Block Z — NetbootController end-to-end integration spec.
#
# The existing netboot_controller_spec covers HTTP wiring (auth, content-type,
# token issuance side-effect). This spec is heavier: it exercises the FULL
# chain — controller → BootstrapService → BootstrapToken.issue! →
# NetbootService.render_ipxe_script → ERB render of the actual on-disk
# template at extensions/system/initramfs/images/ipxe/template.ipxe.erb.
#
# Catches:
#   - ERB syntax regressions in the template
#   - Variable-renaming drift between BootstrapService + ipxe template
#   - Missing kernel cmdline flags (lockdown, IMA, ima_template)
#   - Architecture-detection placeholder mismatch
RSpec.describe "Netboot iPXE end-to-end", type: :request do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform) }
  let(:node)     { create(:system_node, account: account, node_template: template) }
  let(:instance) { create(:system_node_instance, :running, node: node) }
  let(:user)     { user_with_permissions("system.instances.create", account: account) }

  describe "the full render chain" do
    it "produces a valid iPXE script with all required boot directives" do
      get "/api/v1/system/netboot/#{instance.id}/script.ipxe",
          headers: auth_headers_for(user),
          params: { image_base: "https://platform.example/.well-known/powernode/images" }

      expect(response).to have_http_status(:ok)
      script = response.body

      # Shebang — iPXE refuses to run anything else.
      expect(script).to include("#!ipxe")
      # Architecture detection — required for amd64/arm64 dispatch on real iron.
      expect(script).to include("set arch ${buildarch}")
      # Kernel cmdline flags — security architecture enforcement.
      expect(script).to include("lockdown=integrity")
      expect(script).to include("ima_appraise=enforce")
      expect(script).to include("ima_template=ima-ng")
      expect(script).to include("powernode.boot=1")
      # Bootstrap secrets — these are the per-instance variables the
      # template's ERB substitutions must populate.
      expect(script).to include("powernode.bootstrap_token=")
      expect(script).to include("powernode.instance_uuid=#{instance.id}")
      # Image fetch directives — kernel + initrd fetched relative to image_base + arch.
      expect(script).to include("kernel https://platform.example/.well-known/powernode/images")
      expect(script).to include("initrd https://platform.example/.well-known/powernode/images")
      expect(script).to include("/${arch}/kernel")
      expect(script).to include("/${arch}/initramfs.cpio.zst")
      # Boot directive — last step before the kernel takes over.
      expect(script).to include("\nboot\n")
    end

    it "produces a single-use bootstrap token that's findable in the DB" do
      get "/api/v1/system/netboot/#{instance.id}/script.ipxe",
          headers: auth_headers_for(user)
      expect(response).to have_http_status(:ok)

      # Pull the token plaintext out of the rendered script + assert it
      # corresponds to a real System::BootstrapToken row.
      match = response.body.match(/powernode\.bootstrap_token=(\S+)/)
      expect(match).not_to be_nil
      plaintext = match[1]
      token_record = System::BootstrapToken.find_active_by_plaintext(plaintext)
      expect(token_record).to be_present
      expect(token_record.intended_subject).to eq(instance.id)
      expect(token_record.single_use).to be true
      expect(token_record.expires_at).to be > Time.current
    end

    it "issues a fresh token each call so chained re-renders don't share secret" do
      get "/api/v1/system/netboot/#{instance.id}/script.ipxe", headers: auth_headers_for(user)
      first_match = response.body.match(/powernode\.bootstrap_token=(\S+)/)[1]

      get "/api/v1/system/netboot/#{instance.id}/script.ipxe", headers: auth_headers_for(user)
      second_match = response.body.match(/powernode\.bootstrap_token=(\S+)/)[1]

      expect(first_match).not_to eq(second_match)
    end

    it "honors the ttl_minutes parameter" do
      get "/api/v1/system/netboot/#{instance.id}/script.ipxe",
          headers: auth_headers_for(user), params: { ttl_minutes: 5 }
      plaintext = response.body.match(/powernode\.bootstrap_token=(\S+)/)[1]
      token = System::BootstrapToken.find_active_by_plaintext(plaintext)
      expect(token.expires_at).to be_within(30.seconds).of(5.minutes.from_now)
    end

    it "uses ca_pem_url when POWERNODE_CA_PEM_URL is set (chain >1 cert path)" do
      original = ENV["POWERNODE_CA_PEM_URL"]
      ENV["POWERNODE_CA_PEM_URL"] = "https://platform.example/.well-known/powernode-ca.pem"
      begin
        get "/api/v1/system/netboot/#{instance.id}/script.ipxe", headers: auth_headers_for(user)
        expect(response.body).to include("powernode.ca_url=https://platform.example/.well-known/powernode-ca.pem")
        expect(response.body).not_to include("powernode.ca=-----BEGIN CERTIFICATE-----")
      ensure
        ENV["POWERNODE_CA_PEM_URL"] = original
      end
    end

    it "embeds a fallback failure path so an iPXE chainload error doesn't brick the box" do
      get "/api/v1/system/netboot/#{instance.id}/script.ipxe", headers: auth_headers_for(user)
      # Template has a `:failed` label that drops to shell — operators should
      # always have an interactive recovery path on iPXE failure.
      expect(response.body).to include(":failed")
      expect(response.body).to include("shell")
    end
  end

  describe "the template file itself" do
    it "exists at the path NetbootService expects" do
      expect(File.exist?(System::NetbootService::IPXE_TEMPLATE_PATH)).to be true
    end

    it "is valid ERB (renders without raising)" do
      template_src = File.read(System::NetbootService::IPXE_TEMPLATE_PATH)
      ctx = System::NetbootService::IpxeRenderContext.new(
        instance_uuid: "uuid-1",
        bootstrap_token: "tok-1",
        ca_pem_url: nil,
        ca_pem_inline: "FIXTURE",
        image_base: "https://example/imgs"
      )
      expect {
        ERB.new(template_src, trim_mode: "-").result(ctx.get_binding)
      }.not_to raise_error
    end
  end
end
