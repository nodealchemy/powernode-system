# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::Providers::Proxmox::EnrollmentSeed do
  let(:instance) { create(:system_node_instance) }
  let(:ca_pem) { "-----BEGIN CERTIFICATE-----\nFAKE-LE-CHAIN\n-----END CERTIFICATE-----" }
  let(:platform_url) { "https://dev.ipnode.us" }

  def stub_site_setting(ca: nil, url: nil)
    allow(::SiteSetting).to receive(:get).and_call_original
    allow(::SiteSetting).to receive(:get).with("system.ci_builder.enroll_ca_pem").and_return(ca)
    allow(::SiteSetting).to receive(:get).with("system.ci_builder.enroll_platform_url").and_return(url)
  end

  describe ".build" do
    context "when both enroll_ca_pem and enroll_platform_url resolve" do
      before { stub_site_setting(ca: ca_pem, url: platform_url) }

      it "issues a BootstrapToken scoped to the instance's node + purpose proxmox_uefi_provision" do
        expect(::System::BootstrapToken).to receive(:issue!).with(
          node: instance.node,
          node_instance: instance,
          intended_subject: instance.id,
          ttl: 1.hour,
          purpose: "proxmox_uefi_provision"
        ).and_call_original

        described_class.build(instance: instance)
      end

      it "builds exactly the 5 identity fw_cfg entries, mirroring LocalQemu::CloudSeed's keys" do
        result = described_class.build(instance: instance)

        expect(result).to be_present
        entries = result[:fw_cfg_entries]
        expect(entries.keys).to match_array(%w[
          opt/com.powernode/instance_uuid
          opt/com.powernode/instance_name
          opt/com.powernode/bootstrap_token
          opt/com.powernode/ca_pem
          opt/com.powernode/platform_url
        ])
        expect(entries["opt/com.powernode/instance_uuid"]).to eq(instance.id)
        expect(entries["opt/com.powernode/instance_name"]).to eq(instance.name)
        expect(entries["opt/com.powernode/ca_pem"]).to eq(ca_pem)
        expect(entries["opt/com.powernode/platform_url"]).to eq(platform_url)
      end

      it "returns the ONE-TIME plaintext bootstrap token, and it verifies against the persisted (hashed) token row" do
        result = described_class.build(instance: instance)

        plaintext = result[:fw_cfg_entries]["opt/com.powernode/bootstrap_token"]
        expect(plaintext).to be_present

        token = ::System::BootstrapToken.find(result[:bootstrap_token_id])
        expect(token.node_instance).to eq(instance)
        expect(token.purpose).to eq("proxmox_uefi_provision")
        expect(token.single_use).to be true
        expect(token.expires_at).to be_within(5.seconds).of(1.hour.from_now)
        # The DB never stores the plaintext — only its SHA-256 hash.
        expect(token.token_hash).to eq(::System::BootstrapToken.hash_for(plaintext))
        expect(::System::BootstrapToken.find_active_by_plaintext(plaintext)).to eq(token)
      end

      it "falls back to ENV when SiteSetting isn't configured" do
        stub_site_setting(ca: nil, url: nil)
        begin
          ENV["POWERNODE_ENROLL_CA_PEM"] = ca_pem
          ENV["POWERNODE_ENROLL_PLATFORM_URL"] = platform_url

          result = described_class.build(instance: instance)

          expect(result).to be_present
          expect(result[:fw_cfg_entries]["opt/com.powernode/ca_pem"]).to eq(ca_pem)
          expect(result[:fw_cfg_entries]["opt/com.powernode/platform_url"]).to eq(platform_url)
        ensure
          ENV.delete("POWERNODE_ENROLL_CA_PEM")
          ENV.delete("POWERNODE_ENROLL_PLATFORM_URL")
        end
      end
    end

    context "when enroll_ca_pem is not configured (platform_url alone is not enough)" do
      before { stub_site_setting(ca: nil, url: platform_url) }

      it "returns nil, warns, and never issues a BootstrapToken" do
        expect(::System::BootstrapToken).not_to receive(:issue!)
        expect(Rails.logger).to receive(:warn).with(/enrollment identity not staged for #{instance.id}/)

        expect(described_class.build(instance: instance)).to be_nil
      end
    end

    context "when enroll_platform_url is not configured (ca_pem alone is not enough)" do
      before { stub_site_setting(ca: ca_pem, url: nil) }

      it "returns nil, warns, and never issues a BootstrapToken" do
        expect(::System::BootstrapToken).not_to receive(:issue!)
        expect(Rails.logger).to receive(:warn).with(/enrollment identity not staged for #{instance.id}/)

        expect(described_class.build(instance: instance)).to be_nil
      end
    end

    context "when nothing is configured (default / pre-fix behavior — no regression)" do
      before { stub_site_setting(ca: nil, url: nil) }

      it "returns nil without issuing a BootstrapToken" do
        expect(::System::BootstrapToken).not_to receive(:issue!)

        expect(described_class.build(instance: instance)).to be_nil
      end
    end

    context "never falls back to an internal CA default, even if InternalCaService is defined" do
      before do
        stub_site_setting(ca: nil, url: platform_url)
        stub_const("System::InternalCaService", Class.new do
          def self.ca_chain_pem
            "SHOULD-NEVER-BE-USED-BY-ENROLLMENT-SEED"
          end
        end)
      end

      it "still returns nil rather than silently using the internal CA" do
        expect(described_class.build(instance: instance)).to be_nil
      end
    end
  end

  # Option 3 — the API-token-safe cicustom (NoCloud) counterpart to #build.
  describe "#render_cicustom" do
    subject(:seed) { described_class.new }

    context "when both enroll_ca_pem and enroll_platform_url resolve" do
      before { stub_site_setting(ca: ca_pem, url: platform_url) }

      it "issues a BootstrapToken scoped to the instance's node + purpose proxmox_uefi_provision" do
        expect(::System::BootstrapToken).to receive(:issue!).with(
          node: instance.node,
          node_instance: instance,
          intended_subject: instance.id,
          ttl: 1.hour,
          purpose: "proxmox_uefi_provision"
        ).and_call_original

        seed.render_cicustom(instance: instance)
      end

      it "renders user_data as the sourced-shell identity.cfg format the agent's LocalIdentityStrategy parses" do
        result = seed.render_cicustom(instance: instance)

        expect(result).to be_present
        plaintext = result[:user_data][/^KEY=(.+)$/, 1]
        expect(plaintext).to be_present
        expect(result[:user_data]).to eq(
          "ID=#{instance.id}\n" \
          "KEY=#{plaintext}\n" \
          "SERVER=#{platform_url}\n" \
          "CA_PEM_FILE=/run/powernode/enroll-ca.pem\n"
        )
      end

      it "renders meta_data as the raw CA PEM (no wrapping/transformation)" do
        result = seed.render_cicustom(instance: instance)
        expect(result[:meta_data]).to eq(ca_pem)
      end

      it "returns the ONE-TIME plaintext bootstrap token embedded in KEY=, and it verifies against the persisted (hashed) token row" do
        result = seed.render_cicustom(instance: instance)

        plaintext = result[:user_data][/^KEY=(.+)$/, 1]
        expect(plaintext).to be_present

        token = ::System::BootstrapToken.find_active_by_plaintext(plaintext)
        expect(token).to be_present
        expect(token.node_instance).to eq(instance)
        expect(token.purpose).to eq("proxmox_uefi_provision")
        expect(token.single_use).to be true
        expect(token.expires_at).to be_within(5.seconds).of(1.hour.from_now)
        # The DB never stores the plaintext — only its SHA-256 hash.
        expect(token.token_hash).to eq(::System::BootstrapToken.hash_for(plaintext))
      end

      it "never logs the plaintext bootstrap token" do
        # Record everything logged (including ActiveRecord's own SQL debug
        # logging, which we must NOT break) and assert the plaintext never
        # appears in any of it — narrower + more robust than blanket
        # "not_to receive", which would false-fail on unrelated query logs.
        logged = []
        %i[debug info warn error].each do |level|
          allow(Rails.logger).to receive(level) do |msg = nil, &blk|
            logged << (msg || blk&.call).to_s
          end
        end

        result = seed.render_cicustom(instance: instance)
        plaintext = result[:user_data][/^KEY=(.+)$/, 1]

        expect(logged.join("\n")).not_to include(plaintext)
      end

      it "falls back to ENV when SiteSetting isn't configured" do
        stub_site_setting(ca: nil, url: nil)
        begin
          ENV["POWERNODE_ENROLL_CA_PEM"] = ca_pem
          ENV["POWERNODE_ENROLL_PLATFORM_URL"] = platform_url

          result = seed.render_cicustom(instance: instance)

          expect(result).to be_present
          expect(result[:meta_data]).to eq(ca_pem)
          expect(result[:user_data]).to include("SERVER=#{platform_url}")
        ensure
          ENV.delete("POWERNODE_ENROLL_CA_PEM")
          ENV.delete("POWERNODE_ENROLL_PLATFORM_URL")
        end
      end
    end

    context "when enroll_ca_pem is not configured (platform_url alone is not enough)" do
      before { stub_site_setting(ca: nil, url: platform_url) }

      it "returns nil, warns, and never issues a BootstrapToken" do
        expect(::System::BootstrapToken).not_to receive(:issue!)
        expect(Rails.logger).to receive(:warn).with(/enrollment identity not staged for #{instance.id}/)

        expect(seed.render_cicustom(instance: instance)).to be_nil
      end
    end

    context "when enroll_platform_url is not configured (ca_pem alone is not enough)" do
      before { stub_site_setting(ca: ca_pem, url: nil) }

      it "returns nil, warns, and never issues a BootstrapToken" do
        expect(::System::BootstrapToken).not_to receive(:issue!)
        expect(Rails.logger).to receive(:warn).with(/enrollment identity not staged for #{instance.id}/)

        expect(seed.render_cicustom(instance: instance)).to be_nil
      end
    end

    context "when nothing is configured (opt-in gate: no regression)" do
      before { stub_site_setting(ca: nil, url: nil) }

      it "returns nil without issuing a BootstrapToken" do
        expect(::System::BootstrapToken).not_to receive(:issue!)

        expect(seed.render_cicustom(instance: instance)).to be_nil
      end
    end

    context "never falls back to an internal CA default, even if InternalCaService is defined" do
      before do
        stub_site_setting(ca: nil, url: platform_url)
        stub_const("System::InternalCaService", Class.new do
          def self.ca_chain_pem
            "SHOULD-NEVER-BE-USED-BY-ENROLLMENT-SEED"
          end
        end)
      end

      it "still returns nil rather than silently using the internal CA" do
        expect(seed.render_cicustom(instance: instance)).to be_nil
      end
    end
  end
end
