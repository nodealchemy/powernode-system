# frozen_string_literal: true

require "rails_helper"

# Reverse-proxy compose skill — regenerates an account's Traefik dynamic
# config from a valid certificate.
RSpec.describe System::Ai::Skills::ReverseProxyComposeExecutor do
  let(:account) { create(:account) }
  let(:exec)    { described_class.new(account: account) }

  describe ".descriptor" do
    it "advertises certificate_id as a required input" do
      d = described_class.descriptor
      expect(d[:name]).to eq("reverse_proxy_compose")
      expect(d[:category]).to eq("devops")
      expect(d[:requires_approval]).to be false
      expect(d.dig(:inputs, :certificate_id, :required)).to be true
    end
  end

  describe "#execute" do
    context "with a valid certificate" do
      let(:cert) { create(:system_acme_certificate, :valid, account: account) }

      before do
        allow(::Acme::TraefikConfigWriter).to receive(:write!).with(account: account)
          .and_return(output_path: "/etc/traefik/dynamic/acme-#{account.id}.yaml", cert_count: 3)
      end

      it "regenerates the dynamic config and returns the path" do
        r = exec.execute(certificate_id: cert.id)

        expect(r[:success]).to be true
        d = r[:data]
        expect(d[:certificate_id]).to eq(cert.id)
        expect(d[:common_name]).to eq(cert.common_name)
        expect(d[:status]).to eq("valid")
        expect(d[:dynamic_config_path]).to eq("/etc/traefik/dynamic/acme-#{account.id}.yaml")
        expect(d[:routers_configured]).to eq(3)
      end

      it "delegates to TraefikConfigWriter.write! scoped to the account" do
        exec.execute(certificate_id: cert.id)
        expect(::Acme::TraefikConfigWriter).to have_received(:write!).with(account: account)
      end
    end

    context "with a non-valid certificate" do
      let(:cert) { create(:system_acme_certificate, :expired, account: account) }

      it "fails without invoking the writer" do
        allow(::Acme::TraefikConfigWriter).to receive(:write!)
        r = exec.execute(certificate_id: cert.id)

        expect(r[:success]).to be false
        expect(r[:error]).to match(/must be valid/)
        expect(::Acme::TraefikConfigWriter).not_to have_received(:write!)
      end
    end

    context "when the certificate is missing" do
      it "fails fast" do
        r = exec.execute(certificate_id: SecureRandom.uuid)
        expect(r[:success]).to be false
        expect(r[:error]).to match(/Certificate not found/)
      end
    end
  end
end
