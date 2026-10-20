# frozen_string_literal: true

require "rails_helper"

# D12: ProvisioningService injects the provisioning document v1 as the
# user-data head for the cloud providers, fail-closed without a CA.
RSpec.describe System::ProvisioningService, "platform-injected enrolment seed" do
  let(:account)       { create(:account) }
  let(:node)          { create(:system_node, account: account) }
  let(:region)        { create(:system_provider_region, account: account) }
  let(:instance_type) { create(:system_provider_instance_type, account: account) }
  let(:ptype)         { "aws" }
  let(:adapter)       { instance_double("System::Providers::BaseProvider", provider_type: ptype, supports?: true) }
  let(:captured)      { [] }

  before do
    stub_enroll_settings(ca: self_signed_ca_pem)
    allow(System::Providers::Registry).to receive(:for_node).and_return(adapter)
    allow(::Powernode::BillingBridge).to receive(:check_provisioning_quota).and_return({ allowed: true })
    allow(adapter).to receive(:create_instance) do |params|
      captured << params
      { success: true, cloud_instance_id: "i-seed-#{captured.size}", status: "running" }
    end
  end

  def provision(options: {})
    described_class.provision_instance(
      node: node, provider_region_id: region.id, provider_instance_type_id: instance_type.id, options: options
    )
  end

  def audit_rows
    AuditLog.where(resource_type: "System::BootstrapToken", action: "system.bootstrap_token.issued")
  end

  %w[aws openstack].each do |type|
    context "#{type}" do
      let(:ptype) { type }

      it "puts the v1 document first in user_data, with the template init_script as a second MIME part" do
        node.node_template.update!(config: { "init_script" => "#cloud-config\nruncmd: [ls]" })
        expect { provision }.to change { audit_rows.count }.by(1)

        ud = captured.first[:user_data]
        expect(ud).to start_with("MIME-Version: 1.0")
        expect(ud.index("application/x-powernode-provision+json")).to be < ud.index("text/cloud-config")
        expect(JSON.parse(ud[/^\{.*\}$/])).to include("version" => 1, "purpose" => "cloud_seed")
      end

      it "is bare v1 JSON when there is no init script" do
        provision
        expect(JSON.parse(captured.first[:user_data])).to include("version" => 1, "ca_fingerprint" => a_string_starting_with("sha256:"))
      end
    end
  end

  %w[gcp azure].each do |type|
    context "#{type}" do
      let(:ptype) { type }

      it "keeps user_data the bare v1 document and routes the operator script to its own channel" do
        provision(options: { user_data: "echo operator" })

        params = captured.first
        expect(JSON.parse(params[:user_data])).to include("version" => 1)
        expect(params[:user_data]).not_to include("echo operator")
        if type == "gcp"
          expect(params[:startup_script]).to eq("echo operator")
        else
          expect(params[:init_script]).to eq("echo operator")
        end
      end
    end
  end

  context "fail closed (no CA configured)" do
    before { stub_enroll_settings(ca: nil) }

    %w[aws openstack gcp azure].each do |type|
      context type do
        let(:ptype) { type }

        it "errs clearly, creates no cloud instance, mints nothing" do
          result = nil
          expect { result = provision }.not_to change { [ System::BootstrapToken.count, audit_rows.count ] }

          expect(result).not_to be_success
          expect(result.error).to match(/no CA certificate configured/)
          expect(adapter).not_to have_received(:create_instance)
        end
      end
    end
  end

  context "providers outside the cloud-metadata set" do
    let(:ptype) { "mock" }

    it "leaves user_data to the override/template exactly as before and mints nothing" do
      expect { provision(options: { user_data: "echo operator" }) }.not_to change { audit_rows.count }
      expect(captured.first[:user_data]).to eq("echo operator")
    end
  end

  it "never logs the key" do
    io = StringIO.new
    sink = Logger.new(io)
    Rails.logger.broadcast_to(sink)
    provision
    Rails.logger.stop_broadcasting_to(sink)
    key = JSON.parse(captured.first[:user_data])["key"]
    expect(io.string).not_to include(key)
  end
end
