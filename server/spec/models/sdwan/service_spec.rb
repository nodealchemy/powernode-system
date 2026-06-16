# frozen_string_literal: true

require "rails_helper"

RSpec.describe Sdwan::Service, type: :model do
  let(:account) { Account.first || create(:account) }

  def build_service(**attrs)
    described_class.new(
      { account: account, slug: "svc-#{SecureRandom.hex(3)}", name: "Grafana",
        protocol: "https", backend_host: "10.20.0.5", backend_port: 3000 }.merge(attrs)
    )
  end

  describe "validations" do
    it "is valid with a static backend host" do
      expect(build_service).to be_valid
    end

    it "is valid with a VIP backend and no static host" do
      # backend_present is satisfied by backend_vip_id alone (validation reads the
      # id, not the association), so no full SDWAN network/peer graph is needed.
      svc = build_service(backend_host: nil)
      svc.backend_vip_id = SecureRandom.uuid
      expect(svc.valid?).to be(true)
    end

    it "requires a backend (vip or host)" do
      svc = build_service(backend_host: nil)
      expect(svc).not_to be_valid
      expect(svc.errors[:base].join).to match(/backend/)
    end

    it "rejects reserved slugs that would alias a platform router" do
      %w[api agent cable sidekiq svc].each do |reserved|
        expect(build_service(slug: reserved)).not_to be_valid
      end
    end

    it "rejects a non-DNS-label slug" do
      expect(build_service(slug: "Bad_Slug")).not_to be_valid
      expect(build_service(slug: "-leading")).not_to be_valid
    end

    it "enforces slug uniqueness per account" do
      build_service(slug: "dup-svc").save!
      expect(build_service(slug: "dup-svc")).not_to be_valid
    end

    it "allows local exposure only for http/https protocols" do
      expect(build_service(protocol: "tcp", local_enabled: true)).not_to be_valid
      expect(build_service(protocol: "https", local_enabled: true)).to be_valid
    end

    it "requires a permission or group for scoped local auth" do
      expect(build_service(local_enabled: true, local_auth_mode: "scoped")).not_to be_valid
      expect(
        build_service(local_enabled: true, local_auth_mode: "scoped",
                      local_required_permission: "services.grafana.view")
      ).to be_valid
    end

    it "rejects an auth mode outside the enum" do
      expect(build_service(local_auth_mode: "wide-open")).not_to be_valid
    end

    it "rejects a backend_port out of range" do
      expect(build_service(backend_port: 0)).not_to be_valid
      expect(build_service(backend_port: 70_000)).not_to be_valid
    end

    it "rejects a local_certificate owned by another account" do
      # Two explicitly-distinct accounts: the lazy `Account.first` let can't be
      # relied on here (in a clean DB the cert's account would become first).
      svc_account = create(:account)
      cert_account = create(:account)
      cert = create(:system_acme_certificate, :valid, account: cert_account,
                                                       dns_credential: create(:system_acme_dns_credential, :valid, account: cert_account))
      svc = build_service(account: svc_account, local_certificate: cert)
      expect(svc).not_to be_valid
      expect(svc.errors[:local_certificate_id].join).to match(/same account/)
    end
  end

  describe "helpers" do
    it "derives the /svc path prefix and router key" do
      svc = build_service(slug: "grafana")
      svc.save!
      expect(svc.local_path_prefix).to eq("/svc/grafana")
      expect(svc.local_router_slug).to eq("localsvc-#{svc.id}")
    end

    it "builds the backend URL from a static host" do
      expect(build_service.backend_url).to eq("https://10.20.0.5:3000")
    end

    it "brackets IPv6 backend hosts in the URL authority" do
      expect(build_service(backend_host: "2001:db8::5").backend_url).to eq("https://[2001:db8::5]:3000")
    end
  end
end
