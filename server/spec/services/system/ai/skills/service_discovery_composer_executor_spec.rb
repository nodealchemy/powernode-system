# frozen_string_literal: true

require "rails_helper"

# Phase 3 service-discovery composer — SDWAN-native. Chains a Virtual IP
# (auto-advertised via iBGP) → a VIP-backed federation catalog offering →
# a local Traefik route regen → an OPTIONAL public DNS record.
#
# The boundary collaborators are stubbed so the spec asserts the composition
# + id threading + reuse/rollback semantics rather than the underlying
# primitives:
#   - Sdwan::Executors::CreateVirtualIp (VIP primitive)
#   - Federation::ServiceRouteWriter (Traefik regen — touches the filesystem)
#   - Acme::DnsClient.for(...) (public DNS adapter)
# The catalog offering is a real ActiveRecord row (cheap; lets us assert the
# VIP-backed wiring + reuse-by-slug directly).
RSpec.describe System::Ai::Skills::ServiceDiscoveryComposerExecutor do
  let(:account) { create(:account) }
  let(:network) { create(:sdwan_network, account: account) }
  let(:backend) { create(:sdwan_peer, account: account, network: network) }
  let(:exec)    { described_class.new(account: account) }

  let(:vip_cidr) { "fd00:beef::a/128" }

  # ── Default happy-path stubs ───────────────────────────────────────────

  # CreateVirtualIp persists a real VIP row and returns the base executor's
  # { success:, data: { vip_id:, address: } } shape. We materialize the row
  # so the executor's `VirtualIp.find(vip_id)` (and the offering FK) resolve.
  def stub_create_vip(holder: backend)
    allow(::Sdwan::Executors::CreateVirtualIp).to receive(:execute) do |params, **|
      attrs = params[:attributes].symbolize_keys
      vip = network.virtual_ips.create!(
        account: account,
        name: attrs[:name],
        cidr: attrs[:cidr],
        holder_peer_ids: Array(attrs[:holder_peer_ids]),
        state: attrs[:state] || "active",
        anycast: attrs[:anycast] || false
      )
      { success: true, data: { vip_id: vip.id, address: vip.cidr.split("/").first } }
    end
  end

  def stub_route_writer(output_path: "/etc/traefik/dynamic/service-subscriptions-#{0}.yaml", route_count: 0)
    allow(::Federation::ServiceRouteWriter).to receive(:write!)
      .and_return({ output_path: output_path, route_count: route_count })
  end

  describe ".descriptor" do
    it "advertises required inputs, structured outputs, approval gating, and rollback" do
      d = described_class.descriptor

      expect(d[:name]).to eq("service_discovery_composer")
      expect(d[:category]).to eq("devops")
      expect(d[:requires_approval]).to be true
      expect(d[:rollback]).to eq(:rollback_service_discovery_composer)
      expect(d[:blast_radius]).to eq(:medium)

      %i[service_name service_slug sdwan_network_id backend_peer_id backend_port vip_cidr].each do |k|
        expect(d.dig(:inputs, k, :required)).to be(true), "expected #{k} to be required"
      end
      expect(d.dig(:inputs, :public_dns, :required)).to be false
      expect(d[:outputs].keys).to include(:vip_id, :offering_id, :route_output_path,
                                          :dns_record_id, :public_dns_published,
                                          :steps_completed, :warnings)
    end

    it "binds to the System Topology Designer" do
      reg = System::Ai::Skills::SkillBindings.all
                                             .find { |r| r[:executor].name == described_class.name }
      expect(reg).to be_present
      expect(reg[:agents]).to include("System Topology Designer")
    end
  end

  describe "#execute — validation" do
    it "rejects an unknown protocol" do
      r = exec.execute(service_name: "Orders", service_slug: "orders-api",
                       sdwan_network_id: network.id, backend_peer_id: backend.id,
                       backend_port: 8080, vip_cidr: vip_cidr, protocol: "smtp")
      expect(r[:success]).to be false
      expect(r[:error]).to match(/protocol must be one of/)
    end

    it "rejects an unknown network" do
      r = exec.execute(service_name: "Orders", service_slug: "orders-api",
                       sdwan_network_id: SecureRandom.uuid, backend_peer_id: backend.id,
                       backend_port: 8080, vip_cidr: vip_cidr)
      expect(r[:success]).to be false
      expect(r[:error]).to match(/SDWAN network not found/)
    end

    it "rejects a backend peer that is not in the network" do
      other = create(:sdwan_peer, account: account)
      r = exec.execute(service_name: "Orders", service_slug: "orders-api",
                       sdwan_network_id: network.id, backend_peer_id: other.id,
                       backend_port: 8080, vip_cidr: vip_cidr)
      expect(r[:success]).to be false
      expect(r[:error]).to match(/is not a peer in network/)
    end
  end

  describe "#execute — happy path (overlay-only, no public DNS)" do
    before do
      stub_create_vip
      stub_route_writer
    end

    it "creates a VIP, a VIP-backed offering, regenerates routes, and threads ids" do
      r = exec.execute(service_name: "Orders API", service_slug: "orders-api",
                       sdwan_network_id: network.id, backend_peer_id: backend.id,
                       backend_port: 8080, vip_cidr: vip_cidr)

      expect(r[:success]).to be true
      d = r[:data]

      # VIP created + seats the backend peer as primary holder (the iBGP
      # advertiser — that's the in-overlay discovery substrate).
      vip = ::Sdwan::VirtualIp.find(d[:vip_id])
      expect(vip.name).to eq("discovery-orders-api")
      expect(vip.cidr).to eq(vip_cidr)
      expect(Array(vip.holder_peer_ids).first).to eq(backend.id)
      expect(d[:vip_address]).to eq("fd00:beef::a")

      # Offering is VIP-backed (failover-aware backend) + active + advertised.
      offering = ::System::Federation::ServiceOffering.find(d[:offering_id])
      expect(offering.slug).to eq("orders-api")
      expect(offering.name).to eq("Orders API")
      expect(offering.backend_vip_id).to eq(vip.id)
      expect(offering.protocol).to eq("https")
      expect(offering.backend_port).to eq(8080)
      expect(offering.status).to eq("active")

      expect(d[:public_dns_published]).to be false
      expect(d[:dns_record_id]).to be_nil
      expect(d[:steps_completed]).to eq(
        %w[create_virtual_ip create_offering regenerate_traefik_routes]
      )
      expect(d[:warnings]).to be_empty
    end

    it "calls ServiceRouteWriter scoped to the account" do
      expect(::Federation::ServiceRouteWriter).to receive(:write!)
        .with(account: account)
        .and_return({ output_path: "/x", route_count: 2 })

      r = exec.execute(service_name: "Orders", service_slug: "orders-api",
                       sdwan_network_id: network.id, backend_peer_id: backend.id,
                       backend_port: 8080, vip_cidr: vip_cidr)
      expect(r[:success]).to be true
      expect(r[:data][:route_count]).to eq(2)
    end

    it "honors a custom protocol and grant scopes/ttl on the offering" do
      r = exec.execute(service_name: "PG", service_slug: "pg-primary",
                       sdwan_network_id: network.id, backend_peer_id: backend.id,
                       backend_port: 5432, vip_cidr: "10.9.9.9/32",
                       protocol: "tcp", grant_scopes: %w[read write], grant_ttl_days: 14)

      expect(r[:success]).to be true
      offering = ::System::Federation::ServiceOffering.find(r[:data][:offering_id])
      expect(offering.protocol).to eq("tcp")
      expect(offering.default_grant_scopes).to match_array(%w[read write])
      expect(offering.default_grant_ttl_days).to eq(14)
      # A v4 VIP yields a v4 address.
      expect(r[:data][:vip_address]).to eq("10.9.9.9")
    end
  end

  describe "#execute — reuse semantics" do
    before do
      stub_create_vip
      stub_route_writer
    end

    it "reuses an existing VIP by name and reseats the holder instead of creating one" do
      existing = create(:sdwan_virtual_ip, network: network, account: account,
                                           name: "discovery-orders-api",
                                           cidr: "fd00:beef::99/128", holder_peer_ids: [])

      expect(::Sdwan::Executors::CreateVirtualIp).not_to receive(:execute)

      r = exec.execute(service_name: "Orders", service_slug: "orders-api",
                       sdwan_network_id: network.id, backend_peer_id: backend.id,
                       backend_port: 8080, vip_cidr: vip_cidr)

      expect(r[:success]).to be true
      expect(r[:data][:vip_id]).to eq(existing.id)
      expect(r[:data][:vip_cidr]).to eq("fd00:beef::99/128")
      expect(r[:data][:steps_completed]).to include("reuse_virtual_ip")
      expect(Array(existing.reload.holder_peer_ids).first).to eq(backend.id)
    end

    it "reuses an existing offering by slug and repoints its backing service" do
      existing_service = create(:sdwan_service, account: account, slug: "orders-api",
                                                backend_host: "old.example.com", backend_port: 80,
                                                backend_vip_id: nil)
      existing = create(:system_federation_service_offering, :active, account: account,
                                                                      slug: "orders-api",
                                                                      service: existing_service)

      r = exec.execute(service_name: "Orders v2", service_slug: "orders-api",
                       sdwan_network_id: network.id, backend_peer_id: backend.id,
                       backend_port: 9090, vip_cidr: vip_cidr)

      expect(r[:success]).to be true
      expect(r[:data][:offering_id]).to eq(existing.id)
      expect(r[:data][:steps_completed]).to include("reuse_offering")

      existing.reload
      expect(existing.backend_vip_id).to eq(r[:data][:vip_id])  # delegates to service
      expect(existing.name).to eq("Orders v2")
      expect(existing.backend_port).to eq(9090)
    end
  end

  describe "#execute — soft failures (warn, don't abort)" do
    before { stub_create_vip }

    it "still succeeds (with a warning) when Traefik regen fails" do
      allow(::Federation::ServiceRouteWriter).to receive(:write!)
        .and_raise(::Federation::ServiceRouteWriter::WriteError, "permission denied")

      r = exec.execute(service_name: "Orders", service_slug: "orders-api",
                       sdwan_network_id: network.id, backend_peer_id: backend.id,
                       backend_port: 8080, vip_cidr: vip_cidr)

      expect(r[:success]).to be true
      expect(r[:data][:offering_id]).to be_present
      expect(r[:data][:route_output_path]).to be_nil
      expect(r[:data][:steps_completed]).not_to include("regenerate_traefik_routes")
      expect(r[:data][:warnings]).to include(a_string_matching(/traefik route regen failed/))
    end
  end

  describe "#execute — hard failures (abort + rollback)" do
    before { stub_route_writer }

    it "aborts and rolls back the created VIP when the offering fails" do
      stub_create_vip
      # Force the offering create! to blow up (duplicate slug on a different
      # account won't trip uniqueness; instead stub the model create!).
      allow(::System::Federation::ServiceOffering).to receive(:create!)
        .and_raise(ActiveRecord::RecordInvalid.new(::System::Federation::ServiceOffering.new))

      expect {
        r = exec.execute(service_name: "Orders", service_slug: "orders-api",
                         sdwan_network_id: network.id, backend_peer_id: backend.id,
                         backend_port: 8080, vip_cidr: vip_cidr)
        expect(r[:success]).to be false
        expect(r[:error]).to match(/service catalog offering failed/)
      }.not_to change { ::Sdwan::VirtualIp.where(account: account).count }
    end

    it "aborts when VIP creation fails" do
      allow(::Sdwan::Executors::CreateVirtualIp).to receive(:execute)
        .and_return({ success: false, error: "cidr collides with peer overlay" })

      r = exec.execute(service_name: "Orders", service_slug: "orders-api",
                       sdwan_network_id: network.id, backend_peer_id: backend.id,
                       backend_port: 8080, vip_cidr: vip_cidr)

      expect(r[:success]).to be false
      expect(r[:error]).to match(/VIP creation failed/)
      expect(::System::Federation::ServiceOffering.where(account: account)).to be_empty
    end
  end

  describe "#execute — public DNS (internet-facing only)" do
    let(:dns_credential) do
      create(:system_acme_dns_credential, account: account, provider: "cloudflare")
    end
    let(:fake_dns_client) { instance_double("Acme::Cloudflare::DnsClient") }

    before do
      stub_create_vip
      stub_route_writer
      # The executor pulls api_token from Vault then builds the adapter via
      # the factory. Stub the Vault read + the factory so no secret + no HTTP.
      allow_any_instance_of(::Security::VaultCredentialProvider)
        .to receive(:get_credential).and_return({ "api_token" => "tok-xxx" })
      allow(::Acme::DnsClient).to receive(:for)
        .with(provider: "cloudflare", api_token: "tok-xxx")
        .and_return(fake_dns_client)
    end

    def ok_result(data)
      ::Acme::Cloudflare::DnsClient::Result.new(ok: true, data: data, http_status: 200)
    end

    def err_result(msg)
      ::Acme::Cloudflare::DnsClient::Result.new(ok: false, error: msg, http_status: 422)
    end

    it "resolves the hosting zone and publishes an AAAA record pointing at the VIP address" do
      allow(fake_dns_client).to receive(:list_zones)
        .and_return(ok_result([ { "name" => "example.com", "id" => "zone-1" },
                                { "name" => "other.com", "id" => "zone-2" } ]))

      captured = nil
      allow(fake_dns_client).to receive(:create_record) do |zone_id, **kwargs|
        captured = kwargs.merge(zone_id: zone_id)
        ok_result({ "id" => "rec-1" })
      end

      r = exec.execute(service_name: "Orders", service_slug: "orders-api",
                       sdwan_network_id: network.id, backend_peer_id: backend.id,
                       backend_port: 8080, vip_cidr: vip_cidr,
                       public_dns: { dns_credential_id: dns_credential.id,
                                     record_name: "orders.example.com" })

      expect(r[:success]).to be true
      d = r[:data]
      expect(d[:public_dns_published]).to be true
      expect(d[:dns_record_id]).to eq("rec-1")
      expect(d[:dns_record_fqdn]).to eq("orders.example.com")
      expect(d[:steps_completed]).to include("publish_public_dns")

      # Derived AAAA (v6 VIP) pointing at the VIP address, in the longest
      # matching zone.
      expect(captured[:zone_id]).to eq("zone-1")
      expect(captured[:type]).to eq("AAAA")
      expect(captured[:name]).to eq("orders.example.com")
      expect(captured[:content]).to eq("fd00:beef::a")
    end

    it "publishes an operator-supplied CNAME when record_type is CNAME" do
      allow(fake_dns_client).to receive(:list_zones)
        .and_return(ok_result([ { "name" => "example.com", "id" => "zone-1" } ]))

      captured = nil
      allow(fake_dns_client).to receive(:create_record) do |zone_id, **kwargs|
        captured = kwargs.merge(zone_id: zone_id)
        ok_result({ "id" => "rec-cname" })
      end

      r = exec.execute(service_name: "Orders", service_slug: "orders-api",
                       sdwan_network_id: network.id, backend_peer_id: backend.id,
                       backend_port: 8080, vip_cidr: vip_cidr,
                       public_dns: { dns_credential_id: dns_credential.id,
                                     record_name: "orders.example.com",
                                     record_type: "CNAME",
                                     record_content: "edge.example.com",
                                     ttl: 120 })

      expect(r[:success]).to be true
      expect(captured[:type]).to eq("CNAME")
      expect(captured[:content]).to eq("edge.example.com")
      expect(captured[:ttl]).to eq(120)
    end

    it "treats a DNS publish failure as a warning, not an abort (overlay still works)" do
      allow(fake_dns_client).to receive(:list_zones)
        .and_return(ok_result([ { "name" => "example.com", "id" => "zone-1" } ]))
      allow(fake_dns_client).to receive(:create_record).and_return(err_result("record exists"))

      r = exec.execute(service_name: "Orders", service_slug: "orders-api",
                       sdwan_network_id: network.id, backend_peer_id: backend.id,
                       backend_port: 8080, vip_cidr: vip_cidr,
                       public_dns: { dns_credential_id: dns_credential.id,
                                     record_name: "orders.example.com" })

      expect(r[:success]).to be true
      expect(r[:data][:public_dns_published]).to be false
      expect(r[:data][:offering_id]).to be_present
      expect(r[:data][:warnings]).to include(a_string_matching(/public DNS publish failed/))
    end

    it "warns when no hosting zone matches the record name" do
      allow(fake_dns_client).to receive(:list_zones)
        .and_return(ok_result([ { "name" => "unrelated.net", "id" => "zone-9" } ]))
      expect(fake_dns_client).not_to receive(:create_record)

      r = exec.execute(service_name: "Orders", service_slug: "orders-api",
                       sdwan_network_id: network.id, backend_peer_id: backend.id,
                       backend_port: 8080, vip_cidr: vip_cidr,
                       public_dns: { dns_credential_id: dns_credential.id,
                                     record_name: "orders.example.com" })

      expect(r[:success]).to be true
      expect(r[:data][:public_dns_published]).to be false
      expect(r[:data][:warnings]).to include(a_string_matching(/no hosted zone found/))
    end
  end

  describe "#rollback_service_discovery_composer" do
    it "deletes the created VIP and offering, and the DNS record, in reverse order" do
      vip = create(:sdwan_virtual_ip, network: network, account: account,
                                      name: "discovery-orders-api", cidr: vip_cidr,
                                      holder_peer_ids: [ backend.id ])
      service = create(:sdwan_service, account: account, slug: "orders-api",
                                       backend_vip_id: vip.id, backend_host: "backend.example.com")
      offering = create(:system_federation_service_offering, :active, account: account,
                                                                      slug: "orders-api", service: service)
      credential = create(:system_acme_dns_credential, account: account, provider: "cloudflare")

      fake = instance_double("Acme::Cloudflare::DnsClient")
      allow_any_instance_of(described_class).to receive(:dns_client_for).and_return(fake)
      expect(fake).to receive(:delete_record).with("zone-1", "rec-1")
        .and_return(::Acme::Cloudflare::DnsClient::Result.new(ok: true, data: {}, http_status: 200))

      r = exec.rollback_service_discovery_composer(
        vip_id: vip.id, offering_id: offering.id,
        created_vip: true, created_offering: true,
        dns_record_id: "rec-1",
        dns_rollback: { dns_credential_id: credential.id, zone_id: "zone-1" }
      )

      expect(r[:success]).to be true
      expect(::System::Federation::ServiceOffering.where(id: offering.id)).to be_empty
      expect(::Sdwan::VirtualIp.where(id: vip.id)).to be_empty
    end

    it "detaches (not deletes) a reused offering's VIP and preserves the offering" do
      vip = create(:sdwan_virtual_ip, network: network, account: account, cidr: vip_cidr)
      service = create(:sdwan_service, account: account, slug: "orders-api",
                                       backend_vip_id: vip.id, backend_host: "backend.example.com")
      offering = create(:system_federation_service_offering, :active, account: account,
                                                                      slug: "orders-api", service: service)

      r = exec.rollback_service_discovery_composer(
        vip_id: vip.id, offering_id: offering.id,
        created_vip: true, created_offering: false
      )

      expect(r[:success]).to be true
      # Offering survives; its backing service's VIP is detached so the VIP can be removed.
      expect(offering.reload.backend_vip_id).to be_nil
      expect(::Sdwan::VirtualIp.where(id: vip.id)).to be_empty
    end

    it "is a no-op for resources it did not create" do
      vip = create(:sdwan_virtual_ip, network: network, account: account, cidr: vip_cidr)

      r = exec.rollback_service_discovery_composer(vip_id: vip.id, created_vip: false)

      expect(r[:success]).to be true
      expect(::Sdwan::VirtualIp.where(id: vip.id)).to be_present
    end
  end
end
