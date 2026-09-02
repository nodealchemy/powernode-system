# frozen_string_literal: true

require "rails_helper"

# Golden Eclipse M0.M — runtime telemetry (NodeInstance) + promotion lifecycle
# (NodeModuleVersion) extensions.
RSpec.describe "Runtime + promotion extensions", type: :model do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform) }
  let(:node)     { create(:system_node, account: account, node_template: template) }
  let(:instance) { create(:system_node_instance, :running, node: node) }
  let(:node_module) do
    create(:system_node_module, account: account, node_platform: platform,
           category: category, variety: "subscription", name: "nginx-mod")
  end
  let(:version) do
    System::NodeModuleVersion.create!(
      node_module: node_module, version_number: 1,
      mask: [], file_spec: [], package_spec: [], config: {}
    )
  end

  describe "System::NodeModuleVersion promotion lifecycle" do
    it "starts in :built" do
      expect(version.promotion_state).to eq("built")
      expect(version).to be_built
    end

    it "transitions built → staging → blessed → live → retired and stamps timestamps" do
      version.promote_to!(:staging)
      expect(version).to be_staging
      expect(version.staging_baked_at).to be_present

      version.promote_to!(:blessed)
      expect(version).to be_blessed
      expect(version.blessed_at).to be_present

      version.promote_to!(:live)
      expect(version).to be_live
      expect(version.live_at).to be_present

      version.promote_to!(:retired)
      expect(version).to be_retired
      expect(version.retired_at).to be_present
    end

    it "rejects unknown target states" do
      expect { version.promote_to!(:nope) }.to raise_error(ArgumentError, /unknown state/)
    end

    it "rejects invalid transitions (e.g. built → live)" do
      expect { version.promote_to!(:live) }.to raise_error(System::NodeModuleVersion::InvalidTransition)
    end

    it "allows backtracking staging → built (e.g. CI re-bake)" do
      version.promote_to!(:staging)
      expect { version.promote_to!(:built) }.not_to raise_error
      expect(version.reload).to be_built
    end

    it "allows shortcut to retired from any state" do
      version.promote_to!(:staging)
      version.promote_to!(:retired)
      expect(version.reload).to be_retired
    end

    it "exposes scopes for each state" do
      version.promote_to!(:staging)
      v2 = System::NodeModuleVersion.create!(
        node_module: node_module, version_number: 2,
        mask: [], file_spec: [], package_spec: [], config: {}
      )
      expect(System::NodeModuleVersion.staging).to include(version)
      expect(System::NodeModuleVersion.staging).not_to include(v2)
      expect(System::NodeModuleVersion.built).to include(v2)
    end

    it "validates promotion_state inclusion" do
      version.promotion_state = "garbage"
      expect(version).not_to be_valid
      expect(version.errors[:promotion_state]).to be_present
    end
  end

  describe "System::NodeInstance heartbeat + runtime fields" do
    it "starts with stale_heartbeat? true (no heartbeat yet)" do
      expect(instance).to be_stale_heartbeat
    end

    it "records a heartbeat with agent metadata" do
      digests = { node_module.id => "sha256:#{'a' * 64}" }
      instance.record_heartbeat!(
        agent_version: "0.1.0", boot_id: "boot-abc", module_digests: digests
      )
      instance.reload
      expect(instance.last_heartbeat_at).to be_within(5.seconds).of(Time.current)
      expect(instance.agent_version).to eq("0.1.0")
      expect(instance.boot_id).to eq("boot-abc")
      expect(instance.running_module_digests).to eq(digests.transform_keys(&:to_s))
      expect(instance).not_to be_stale_heartbeat
    end

    it "marks heartbeat stale after threshold" do
      instance.record_heartbeat!(agent_version: "0.1", boot_id: "x")
      travel(System::NodeInstance::HEARTBEAT_STALE_AFTER + 1.minute) do
        expect(instance.reload).to be_stale_heartbeat
      end
    end

    # IMP-249aa98969bd — module_first_seen_running_at is the dwell anchor
    # PromotionCriteria needs: when this instance FIRST reported running this
    # exact digest. Stamped by the same heartbeat ingest that records the
    # digest, never overwritten while the digest holds, dropped when it changes.
    describe "#record_heartbeat! first_seen_running_at stamping" do
      let(:digest_a) { "sha256:#{'a' * 64}" }
      let(:digest_b) { "sha256:#{'b' * 64}" }

      def heartbeat!(digests)
        instance.record_heartbeat!(agent_version: "0.1.0", boot_id: "boot-abc", module_digests: digests)
        instance.reload
      end

      it "stamps the first heartbeat reporting a digest on a running instance" do
        heartbeat!(node_module.id => digest_a)

        expect(instance.first_seen_running_at_for(node_module.id)).to be_within(5.seconds).of(Time.current)
      end

      it "never overwrites the stamp while the digest holds" do
        heartbeat!(node_module.id => digest_a)
        first = instance.first_seen_running_at_for(node_module.id)

        travel(20.minutes) { heartbeat!(node_module.id => digest_a) }

        expect(instance.first_seen_running_at_for(node_module.id)).to be_within(1.second).of(first)
      end

      it "re-stamps when the reported digest changes" do
        heartbeat!(node_module.id => digest_a)

        travel(20.minutes) do
          heartbeat!(node_module.id => digest_b)
          expect(instance.first_seen_running_at_for(node_module.id)).to be_within(5.seconds).of(Time.current)
        end
      end

      it "drops the stamp when the module stops being reported" do
        heartbeat!(node_module.id => digest_a)
        heartbeat!({})

        expect(instance.module_first_seen_running_at).to eq({})
        expect(instance.first_seen_running_at_for(node_module.id)).to be_nil
      end

      it "does not stamp a non-running instance" do
        instance.update!(status: "starting")
        heartbeat!(node_module.id => digest_a)

        expect(instance.first_seen_running_at_for(node_module.id)).to be_nil
      end

      # A stamp carried across a REBOOT would credit the version with the whole
      # downtime as dwell — an OVERSTATEMENT, the same unsafe direction the
      # min(last_heartbeat_at) anchor failed in. The boot identity is the
      # discriminator, exactly as it is for booted_image_git_sha.
      it "re-stamps when the node reboots under a new boot_id" do
        heartbeat!(node_module.id => digest_a)
        first = instance.first_seen_running_at_for(node_module.id)

        travel(20.minutes) do
          instance.record_heartbeat!(agent_version: "0.1.0", boot_id: "boot-xyz",
                                     module_digests: { node_module.id => digest_a })
          instance.reload
          expect(instance.first_seen_running_at_for(node_module.id)).to be_within(5.seconds).of(Time.current)
        end

        expect(instance.first_seen_running_at_for(node_module.id)).to be > first + 19.minutes
      end

      it "carries the stamp forward when the heartbeat reports no boot_id" do
        heartbeat!(node_module.id => digest_a)
        first = instance.first_seen_running_at_for(node_module.id)

        travel(20.minutes) do
          instance.record_heartbeat!(agent_version: "0.1.0", boot_id: nil,
                                     module_digests: { node_module.id => digest_a })
          instance.reload
        end

        expect(instance.first_seen_running_at_for(node_module.id)).to be_within(1.second).of(first)
      end
    end

    it "validates architecture inclusion via DB check constraint" do
      expect {
        instance.update_columns(architecture: "powerpc")
      }.to raise_error(ActiveRecord::StatementInvalid, /architecture_check/)
    end

    it "exposes #active_certificate (nil when no certs issued)" do
      expect(instance.active_certificate).to be_nil
    end

    it "returns the most recent active cert from #active_certificate" do
      old_cert = System::NodeCertificate.create!(
        node_instance: instance, serial: SecureRandom.hex(16),
        subject: "CN=#{instance.id}", not_before: 30.days.ago, not_after: 60.days.from_now
      )
      new_cert = System::NodeCertificate.create!(
        node_instance: instance, serial: SecureRandom.hex(16),
        subject: "CN=#{instance.id}", not_before: 1.day.ago, not_after: 89.days.from_now
      )
      old_cert.revoke!(reason: "rotated")
      expect(instance.active_certificate).to eq(new_cert)
    end
  end
end
