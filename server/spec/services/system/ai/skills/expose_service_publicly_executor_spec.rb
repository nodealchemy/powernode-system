# frozen_string_literal: true

require "rails_helper"

# North-star orchestrator #1 — chains SDWAN VIP → port mapping → ACME cert
# → reverse-proxy regen. The SDWAN tool and the two sibling executors are
# stubbed at their boundaries so the spec asserts the chaining + id threading
# rather than the underlying primitives.
RSpec.describe System::Ai::Skills::ExposeServicePubliclyExecutor do
  let(:account)  { create(:account) }

  # APO-1c (IMP-7e2bdc1774e4). This executor declares `requires_approval: true`,
  # and BaseSkillExecutor#execute now resolves Ai::InterventionPolicy BEFORE
  # #perform — an unconfigured category defaults to require_approval, so every
  # example below would park an approval instead of performing. These examples
  # are about what #perform DOES, so an operator policy puts the gate on its
  # proceed branch rather than removing it: the real entry point still runs.
  # See spec/support/skill_gate_helpers.rb.
  before { auto_execute_skill_policy!(account, described_class) }
  let(:network)  { create(:sdwan_network, account: account) }
  let(:hub_peer) { create(:sdwan_peer, network: network) }
  let(:backend)  { create(:sdwan_peer, network: network) }
  let(:exec)     { described_class.new(account: account) }

  let(:vip_id)         { SecureRandom.uuid }
  let(:port_mapping_id) { SecureRandom.uuid }
  let(:certificate_id) { SecureRandom.uuid }
  let(:vip_cidr)       { "fd00:beef::a/128" }

  # Default happy-path stubs for the SDWAN tool actions. The tool wraps its
  # payload under data.virtual_ip / data.port_mapping (BaseTool shape).
  #
  # The create_virtual_ip branch ASSERTS that cidr is threaded through —
  # Sdwan::VirtualIp validates cidr presence, so a missing cidr would raise
  # RecordInvalid in production. Asserting here means that regression (fix #1)
  # can never hide behind a fully-stubbed SdwanTool again.
  def stub_sdwan_happy_path
    allow_any_instance_of(::Ai::Tools::SdwanTool).to receive(:execute) do |_tool, params:|
      case params[:action]
      when "system_sdwan_create_virtual_ip"
        expect(params[:cidr]).to be_present
        { success: true, data: { virtual_ip: { id: vip_id, cidr: params[:cidr] } } }
      when "system_sdwan_create_port_mapping"
        { success: true, data: { port_mapping: { id: port_mapping_id } } }
      else
        { success: false, error: "unexpected action #{params[:action]}" }
      end
    end
  end

  def stub_subexecutors_happy_path
    allow_any_instance_of(System::Ai::Skills::AcmeCertificateProvisionExecutor)
      .to receive(:execute)
      .and_return({ success: true,
                    data: { certificate_id: certificate_id, certificate_status: "valid" } })
    allow_any_instance_of(System::Ai::Skills::ReverseProxyComposeExecutor)
      .to receive(:execute)
      .and_return({ success: true, data: { regenerated: true } })
  end

  describe ".descriptor" do
    it "advertises required inputs, structured outputs, and approval gating" do
      d = described_class.descriptor

      expect(d[:name]).to eq("expose_service_publicly")
      expect(d[:category]).to eq("devops")
      expect(d[:requires_approval]).to be true
      expect(d.dig(:inputs, :service_hostname, :required)).to be true
      expect(d.dig(:inputs, :service_protocol, :required)).to be true
      expect(d.dig(:inputs, :sdwan_network_id, :required)).to be true
      expect(d.dig(:inputs, :sdwan_hub_peer_id, :required)).to be true
      expect(d.dig(:inputs, :vip_cidr, :required)).to be true
      expect(d.dig(:inputs, :backend_port, :required)).to be true
      expect(d.dig(:inputs, :target_peer_id, :required)).to be false
      expect(d[:outputs].keys).to include(:vip_id, :port_mapping_id, :certificate_id,
                                          :public_endpoints, :steps_completed, :warnings)
    end
  end

  describe "#execute — validation" do
    it "rejects an unknown protocol" do
      r = exec.execute(service_hostname: "app.example.com", service_protocol: "ftp",
                       sdwan_network_id: network.id, sdwan_hub_peer_id: hub_peer.id,
                       vip_cidr: vip_cidr,
                       target_peer_id: backend.id, backend_port: 8080)
      expect(r[:success]).to be false
      expect(r[:error]).to match(/service_protocol must be/)
    end

    it "rejects when neither target is provided" do
      r = exec.execute(service_hostname: "app.example.com", service_protocol: "https",
                       sdwan_network_id: network.id, sdwan_hub_peer_id: hub_peer.id,
                       vip_cidr: vip_cidr,
                       backend_port: 8080)
      expect(r[:success]).to be false
      expect(r[:error]).to match(/exactly one of target_peer_id or target_instance_id/)
    end

    it "rejects when both targets are provided" do
      r = exec.execute(service_hostname: "app.example.com", service_protocol: "https",
                       sdwan_network_id: network.id, sdwan_hub_peer_id: hub_peer.id,
                       vip_cidr: vip_cidr,
                       target_peer_id: backend.id, target_instance_id: SecureRandom.uuid,
                       backend_port: 8080)
      expect(r[:success]).to be false
      expect(r[:error]).to match(/exactly one of target_peer_id or target_instance_id/)
    end
  end

  describe "#execute — happy path (https)" do
    before do
      stub_sdwan_happy_path
      stub_subexecutors_happy_path
    end

    it "threads ids across all four steps and records steps_completed" do
      r = exec.execute(service_hostname: "app.example.com", service_protocol: "https",
                       sdwan_network_id: network.id, sdwan_hub_peer_id: hub_peer.id,
                       vip_cidr: vip_cidr,
                       dns_credential_id: SecureRandom.uuid,
                       target_peer_id: backend.id, backend_port: 8080)

      expect(r[:success]).to be true
      d = r[:data]
      expect(d[:vip_id]).to eq(vip_id)
      expect(d[:vip_cidr]).to eq("fd00:beef::a/128")
      expect(d[:port_mapping_id]).to eq(port_mapping_id)
      expect(d[:certificate_id]).to eq(certificate_id)
      expect(d[:certificate_status]).to eq("valid")
      expect(d[:public_endpoints]).to eq([ "https://app.example.com" ])
      expect(d[:steps_completed]).to eq(
        %w[create_virtual_ip create_port_mapping provision_certificate reverse_proxy_regen]
      )
      expect(d[:warnings]).to be_empty
    end

    it "passes the issued certificate_id into the reverse-proxy executor" do
      expect_any_instance_of(System::Ai::Skills::ReverseProxyComposeExecutor)
        .to receive(:execute).with(certificate_id: certificate_id)
        .and_return({ success: true, data: {} })

      exec.execute(service_hostname: "app.example.com", service_protocol: "https",
                   sdwan_network_id: network.id, sdwan_hub_peer_id: hub_peer.id,
                   vip_cidr: vip_cidr,
                       dns_credential_id: SecureRandom.uuid,
                   target_peer_id: backend.id, backend_port: 8080)
    end

    it "passes the VIP id as the port mapping target and listen_port 443" do
      captured = []
      allow_any_instance_of(::Ai::Tools::SdwanTool).to receive(:execute) do |_t, params:|
        captured << params
        case params[:action]
        when "system_sdwan_create_virtual_ip"
          { success: true, data: { virtual_ip: { id: vip_id, cidr: "fd00:beef::a/128" } } }
        else
          { success: true, data: { port_mapping: { id: port_mapping_id } } }
        end
      end

      exec.execute(service_hostname: "app.example.com", service_protocol: "https",
                   sdwan_network_id: network.id, sdwan_hub_peer_id: hub_peer.id,
                   vip_cidr: vip_cidr,
                       dns_credential_id: SecureRandom.uuid,
                   target_peer_id: backend.id, backend_port: 8080)

      pm = captured.find { |p| p[:action] == "system_sdwan_create_port_mapping" }
      expect(pm[:target_virtual_ip_id]).to eq(vip_id)
      expect(pm[:listen_port]).to eq(443)
      expect(pm[:target_port]).to eq(8080)
    end
  end

  describe "#execute — reuse semantics" do
    before do
      stub_sdwan_happy_path
      stub_subexecutors_happy_path
    end

    it "reuses an existing VIP by name instead of creating a new one" do
      create(:sdwan_virtual_ip, network: network, account: account,
                                name: "expose-app.example.com", cidr: "fd00:beef::99/128")

      expect_any_instance_of(::Ai::Tools::SdwanTool).not_to receive(:execute)
        .with(params: hash_including(action: "system_sdwan_create_virtual_ip"))

      r = exec.execute(service_hostname: "app.example.com", service_protocol: "https",
                       sdwan_network_id: network.id, sdwan_hub_peer_id: hub_peer.id,
                       vip_cidr: vip_cidr,
                       dns_credential_id: SecureRandom.uuid,
                       target_peer_id: backend.id, backend_port: 8080)

      expect(r[:success]).to be true
      expect(r[:data][:vip_cidr]).to eq("fd00:beef::99/128")
      expect(r[:data][:steps_completed]).to include("reuse_virtual_ip")
    end

    it "reuses a valid unexpired certificate for the hostname" do
      cert = create(:system_acme_certificate, :valid, account: account,
                                                       common_name: "app.example.com")

      expect_any_instance_of(System::Ai::Skills::AcmeCertificateProvisionExecutor)
        .not_to receive(:execute)

      r = exec.execute(service_hostname: "app.example.com", service_protocol: "https",
                       sdwan_network_id: network.id, sdwan_hub_peer_id: hub_peer.id,
                       vip_cidr: vip_cidr,
                       dns_credential_id: SecureRandom.uuid,
                       target_peer_id: backend.id, backend_port: 8080)

      expect(r[:success]).to be true
      expect(r[:data][:certificate_id]).to eq(cert.id)
      expect(r[:data][:steps_completed]).to include("reuse_certificate")
    end
  end

  describe "#execute — https TLS failures are hard failures (fix #2)" do
    before { stub_sdwan_happy_path }

    it "fails fast (before VIP creation) when dns-01 https is missing dns_credential_id" do
      expect_any_instance_of(::Ai::Tools::SdwanTool).not_to receive(:execute)

      r = exec.execute(service_hostname: "app.example.com", service_protocol: "https",
                       sdwan_network_id: network.id, sdwan_hub_peer_id: hub_peer.id,
                       vip_cidr: vip_cidr,
                       target_peer_id: backend.id, backend_port: 8080)

      expect(r[:success]).to be false
      expect(r[:error]).to match(/dns_credential_id is required/)
    end

    it "fails (not success-with-warning) when cert provisioning fails" do
      allow_any_instance_of(System::Ai::Skills::AcmeCertificateProvisionExecutor)
        .to receive(:execute).and_return({ success: false, error: "dns challenge timed out" })

      r = exec.execute(service_hostname: "app.example.com", service_protocol: "https",
                       sdwan_network_id: network.id, sdwan_hub_peer_id: hub_peer.id,
                       vip_cidr: vip_cidr, dns_credential_id: SecureRandom.uuid,
                       target_peer_id: backend.id, backend_port: 8080)

      expect(r[:success]).to be false
      expect(r[:error]).to match(/certificate provisioning failed/)
    end

    it "fails when reverse-proxy regen fails for an https expose" do
      allow_any_instance_of(System::Ai::Skills::AcmeCertificateProvisionExecutor)
        .to receive(:execute)
        .and_return({ success: true, data: { certificate_id: certificate_id, certificate_status: "valid" } })
      allow_any_instance_of(System::Ai::Skills::ReverseProxyComposeExecutor)
        .to receive(:execute).and_return({ success: false, error: "proxy reload failed" })

      r = exec.execute(service_hostname: "app.example.com", service_protocol: "https",
                       sdwan_network_id: network.id, sdwan_hub_peer_id: hub_peer.id,
                       vip_cidr: vip_cidr, dns_credential_id: SecureRandom.uuid,
                       target_peer_id: backend.id, backend_port: 8080)

      expect(r[:success]).to be false
      expect(r[:error]).to match(/reverse proxy regen failed/)
    end
  end

  describe "#execute — hard failures (abort)" do
    it "fails when VIP creation fails" do
      allow_any_instance_of(::Ai::Tools::SdwanTool).to receive(:execute)
        .and_return({ success: false, error: "no holder peer" })

      r = exec.execute(service_hostname: "app.example.com", service_protocol: "https",
                       sdwan_network_id: network.id, sdwan_hub_peer_id: hub_peer.id,
                       vip_cidr: vip_cidr, dns_credential_id: SecureRandom.uuid,
                       target_peer_id: backend.id, backend_port: 8080)

      expect(r[:success]).to be false
      expect(r[:error]).to match(/VIP creation failed/)
    end

    it "fails when port mapping creation fails" do
      allow_any_instance_of(::Ai::Tools::SdwanTool).to receive(:execute) do |_t, params:|
        if params[:action] == "system_sdwan_create_virtual_ip"
          { success: true, data: { virtual_ip: { id: vip_id, cidr: "fd00:beef::a/128" } } }
        else
          { success: false, error: "hub peer not reachable" }
        end
      end

      r = exec.execute(service_hostname: "app.example.com", service_protocol: "https",
                       sdwan_network_id: network.id, sdwan_hub_peer_id: hub_peer.id,
                       vip_cidr: vip_cidr, dns_credential_id: SecureRandom.uuid,
                       target_peer_id: backend.id, backend_port: 8080)

      expect(r[:success]).to be false
      expect(r[:error]).to match(/port mapping creation failed/)
    end
  end

  describe "#execute — http (no TLS)" do
    before { stub_sdwan_happy_path }

    it "skips the cert step entirely, uses listen_port 80, and succeeds" do
      captured = []
      allow_any_instance_of(::Ai::Tools::SdwanTool).to receive(:execute) do |_t, params:|
        captured << params
        case params[:action]
        when "system_sdwan_create_virtual_ip"
          { success: true, data: { virtual_ip: { id: vip_id, cidr: "fd00:beef::a/128" } } }
        else
          { success: true, data: { port_mapping: { id: port_mapping_id } } }
        end
      end

      # http exposures must not touch the ACME executor at all (no TLS).
      expect_any_instance_of(System::Ai::Skills::AcmeCertificateProvisionExecutor)
        .not_to receive(:execute)

      r = exec.execute(service_hostname: "app.example.com", service_protocol: "http",
                       sdwan_network_id: network.id, sdwan_hub_peer_id: hub_peer.id,
                       vip_cidr: vip_cidr,
                       target_peer_id: backend.id, backend_port: 8080)

      expect(r[:success]).to be true
      expect(r[:data][:certificate_id]).to be_nil
      expect(r[:data][:public_endpoints]).to eq([ "http://app.example.com" ])
      expect(r[:data][:steps_completed]).to eq(%w[create_virtual_ip create_port_mapping])
      pm = captured.find { |p| p[:action] == "system_sdwan_create_port_mapping" }
      expect(pm[:listen_port]).to eq(80)
    end
  end

  describe "#execute — target_instance_id resolution (fix #4)" do
    before do
      stub_sdwan_happy_path
      stub_subexecutors_happy_path
    end

    it "rejects target_instance_id with no SDWAN peer in the network (never a holderless VIP)" do
      expect_any_instance_of(::Ai::Tools::SdwanTool).not_to receive(:execute)

      r = exec.execute(service_hostname: "app.example.com", service_protocol: "http",
                       sdwan_network_id: network.id, sdwan_hub_peer_id: hub_peer.id,
                       vip_cidr: vip_cidr,
                       target_instance_id: SecureRandom.uuid, backend_port: 8080)

      expect(r[:success]).to be false
      expect(r[:error]).to match(/has no SDWAN peer/)
    end

    it "resolves target_instance_id to its peer and seats it as the VIP holder" do
      # Peer must be scoped to the executor's account + the target network for
      # the NodeInstance → Peer resolution to find it.
      account_peer = create(:sdwan_peer, account: account, network: network)

      captured = []
      allow_any_instance_of(::Ai::Tools::SdwanTool).to receive(:execute) do |_t, params:|
        captured << params
        case params[:action]
        when "system_sdwan_create_virtual_ip"
          { success: true, data: { virtual_ip: { id: vip_id, cidr: params[:cidr] } } }
        else
          { success: true, data: { port_mapping: { id: port_mapping_id } } }
        end
      end

      r = exec.execute(service_hostname: "app.example.com", service_protocol: "http",
                       sdwan_network_id: network.id, sdwan_hub_peer_id: hub_peer.id,
                       vip_cidr: vip_cidr,
                       target_instance_id: account_peer.node_instance_id, backend_port: 8080)

      expect(r[:success]).to be true
      vip_params = captured.find { |p| p[:action] == "system_sdwan_create_virtual_ip" }
      expect(vip_params[:holder_peer_ids]).to eq([ account_peer.id ])
    end
  end
end
