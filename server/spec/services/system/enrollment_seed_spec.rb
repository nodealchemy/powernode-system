# frozen_string_literal: true

require "rails_helper"

# D12: the single issuer of platform-injected enrolment keys.
RSpec.describe System::EnrollmentSeed do
  let(:instance) { create(:system_node_instance) }
  let(:ca) { self_signed_ca_pem }

  before { stub_enroll_settings(ca: ca) }

  def audit_rows
    AuditLog.where(resource_type: "System::BootstrapToken", action: "system.bootstrap_token.issued")
  end

  describe ".render_user_data" do
    it "mints a cloud_seed token bound to the instance, 1h, and renders a v1 document with the pin" do
      result = described_class.render_user_data(instance: instance)

      doc = JSON.parse(result.user_data)
      token = System::BootstrapToken.find(result.bootstrap_token_id)
      expect(doc).to include("version" => 1, "instance_id" => instance.id, "purpose" => "cloud_seed")
      expect(doc["ca_fingerprint"]).to match(/\Asha256:\h{64}\z/)
      expect(token).to have_attributes(purpose: "cloud_seed", node_instance_id: instance.id, single_use: true)
      expect(token.expires_at).to be_within(5.seconds).of(1.hour.from_now)
      expect(token.expires_at.utc.iso8601).to eq(doc["expires_at"])
      expect(System::BootstrapToken.find_active_by_plaintext(doc["key"])).to eq(token)
    end

    it "writes exactly one audit row per mint, and re-mints (new key, new row) every call" do
      expect { described_class.render_user_data(instance: instance) }.to change { audit_rows.count }.by(1)
      first = JSON.parse(described_class.render_user_data(instance: instance).user_data)["key"]
      second = JSON.parse(described_class.render_user_data(instance: instance).user_data)["key"]

      expect(first).not_to eq(second)
      expect(audit_rows.count).to eq(3)
    end

    it "never puts the key into an audit row" do
      key = JSON.parse(described_class.render_user_data(instance: instance).user_data)["key"]
      expect(audit_rows.map { |r| r.attributes.to_json }.join).not_to include(key)
    end

    context "when no CA is configured (fail closed)" do
      let(:ca) { nil }

      it "raises SeedError, ships no document and leaves neither a token nor an audit row" do
        expect {
          expect { described_class.render_user_data(instance: instance) }
            .to raise_error(described_class::SeedError, /no CA certificate configured/)
        }.not_to change { [ System::BootstrapToken.count, audit_rows.count ] }
      end
    end

    context "when the platform URL is not https" do
      it "raises SeedError and rolls the mint back" do
        stub_enroll_settings(ca: ca, url: "http://platform.example.test")
        expect {
          expect { described_class.render_user_data(instance: instance) }
            .to raise_error(described_class::SeedError, /plain https URL/)
        }.not_to change { System::BootstrapToken.count }
      end
    end

    context "when the audit write fails" do
      it "fails closed with no token" do
        allow(AuditLog).to receive(:log_action).and_raise(StandardError, "audit down")
        expect { described_class.render_user_data(instance: instance) }
          .to raise_error(System::BootstrapToken::AuditFailure)
        expect(System::BootstrapToken.where(node_instance_id: instance.id).count).to eq(0)
      end
    end

    context "with an init script" do
      it "puts the v1 document first and the script second, as a MIME multipart" do
        result = described_class.render_user_data(instance: instance, extra: "#cloud-config\nruncmd: [ls]")
        mail = result.user_data

        expect(mail).to start_with("MIME-Version: 1.0\nContent-Type: multipart/mixed; boundary=")
        parts = mail.split(/^--powernode-seed-\h+(?:--)?$/).map(&:strip).reject(&:empty?)
        headers = parts.shift
        expect(headers).to include("multipart/mixed")
        expect(parts.first).to include("application/x-powernode-provision+json")
        expect(JSON.parse(parts.first[/^\{.*\}$/])["version"]).to eq(1)
        expect(parts.last).to include("text/cloud-config").and include("runcmd")
      end

      it "types a shebang script as a shell script part" do
        expect(described_class.compose("{}", "#!/bin/sh\necho hi")).to include("Content-Type: text/x-shellscript")
      end
    end
  end

  describe ".issue_token" do
    it "is the one mint path: BootstrapToken.issue! with a 1h ttl bound to the instance" do
      expect(System::BootstrapToken).to receive(:issue!).with(
        node: instance.node, node_instance: instance, intended_subject: instance.id,
        ttl: 1.hour, purpose: "cloud_seed"
      ).and_call_original
      described_class.issue_token(instance: instance)
    end
  end
end
