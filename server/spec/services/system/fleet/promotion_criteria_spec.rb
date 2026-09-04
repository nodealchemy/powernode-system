# frozen_string_literal: true

require "rails_helper"

# Golden Eclipse M7.C — PromotionCriteria.
RSpec.describe System::Fleet::PromotionCriteria do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform) }
  let(:mod) do
    create(:system_node_module, account: account, node_platform: platform,
           category: category, variety: "subscription", name: "promo-mod")
  end
  let(:digest) { "sha256:#{'a' * 64}" }

  let!(:version) do
    System::NodeModuleVersion.create!(
      node_module: mod, version_number: 1,
      mask: [], file_spec: [], package_spec: [], config: {},
      oci_digest: digest,
      promotion_state: "staging"
    )
  end

  # A qualifying instance is one that is `running`, reports the candidate
  # digest, and — post IMP-249aa98969bd — carries BOTH facts the gate weighs:
  # a FRESH heartbeat (it is alive now) and a first_seen_running_at stamp old
  # enough to clear dwell (it has been running this digest long enough).
  # Defaults describe the healthy, long-running fleet the gate exists to bless.
  def qualifying_instance(idx, prefix: "promo-node",
                          heartbeat_at: 5.seconds.ago,
                          first_seen_at: (described_class::DWELL_TIME + 5.minutes).ago)
    node = create(:system_node, account: account, node_template: template, name: "#{prefix}-#{idx}")
    node.node_modules << mod
    create(:system_node_instance, :running, node: node).tap do |inst|
      inst.update!(
        running_module_digests: { mod.id => digest },
        last_heartbeat_at: heartbeat_at,
        module_first_seen_running_at: first_seen_at.nil? ? {} : { mod.id.to_s => first_seen_at.iso8601 }
      )
    end
  end

  describe ".evaluate" do
    context "with no oci_digest" do
      it "returns ineligible" do
        version.update!(oci_digest: nil)
        result = described_class.evaluate(version: version)
        expect(result[:eligible]).to be false
        expect(result[:reason]).to match(/no oci_digest/)
      end
    end

    context "with fewer than REQUIRED_COUNT instances running the digest" do
      it "returns ineligible with running_count" do
        result = described_class.evaluate(version: version)
        expect(result[:eligible]).to be false
        expect(result[:running_count]).to eq(0)
        expect(result[:required_count]).to eq(described_class::REQUIRED_COUNT)
      end
    end

    context "with REQUIRED_COUNT instances at sufficient dwell time" do
      before { described_class::REQUIRED_COUNT.times { |i| qualifying_instance(i) } }

      it "returns eligible" do
        result = described_class.evaluate(version: version)
        expect(result[:eligible]).to be true
        expect(result[:running_count]).to eq(described_class::REQUIRED_COUNT)
        expect(result[:dwell_time_minutes]).to be > (described_class::DWELL_TIME / 60).to_i
      end
    end
  end

  # Configurable thresholds — a 1-2 instance fleet can never reach the
  # baked-in REQUIRED_COUNT of 3, so staging→blessed is unreachable until
  # the operator can tune the bar. Resolution cascade (highest wins):
  # per-module config → per-account settings → SiteSetting global → default.
  describe "configurable thresholds" do
    def make_running_instance(idx, **kwargs)
      qualifying_instance(idx, prefix: "cfg-node", **kwargs)
    end

    context "with a per-account required_count override lowering the bar to 1" do
      before do
        account.update!(settings: { "module_promotion_required_count" => 1 })
        make_running_instance(0)
      end

      it "promotes a single-instance fleet" do
        result = described_class.evaluate(version: version)
        expect(result[:eligible]).to be true
        expect(result[:running_count]).to eq(1)
        expect(result[:required_count]).to eq(1)
      end
    end

    context "with a per-account dwell override of 0 minutes" do
      before do
        account.update!(settings: { "module_promotion_dwell_minutes" => 0 })
        # No dwell stamp at all: a 0-minute override disables the dwell gate
        # outright, exactly as it did before the anchor was fixed, so an
        # instance that has never been stamped still qualifies.
        described_class::REQUIRED_COUNT.times do |i|
          make_running_instance(i, heartbeat_at: 1.minute.ago, first_seen_at: nil)
        end
      end

      it "does not require any dwell time" do
        result = described_class.evaluate(version: version)
        expect(result[:eligible]).to be true
      end
    end

    context "with a per-module config override taking precedence over the account setting" do
      before do
        account.update!(settings: { "module_promotion_required_count" => 5 })
        mod.update!(config: { "module_promotion_required_count" => 1 })
        make_running_instance(0)
      end

      it "uses the module override" do
        result = described_class.evaluate(version: version)
        expect(result[:eligible]).to be true
        expect(result[:required_count]).to eq(1)
      end
    end

    context "with a SiteSetting global override and no per-account/per-module value" do
      before do
        SiteSetting.set("module_promotion_required_count", 1, setting_type: "integer")
        make_running_instance(0)
      end

      it "falls back to the global default" do
        result = described_class.evaluate(version: version)
        expect(result[:eligible]).to be true
        expect(result[:required_count]).to eq(1)
      end
    end

    context "with a required_count override of 0 (below the floor)" do
      before do
        account.update!(settings: { "module_promotion_required_count" => 0 })
        make_running_instance(0)
      end

      it "clamps to a minimum of 1" do
        result = described_class.evaluate(version: version)
        expect(result[:eligible]).to be true
        expect(result[:required_count]).to eq(1)
      end
    end

    context "with no overrides configured" do
      it "preserves the baked-in defaults" do
        expect(described_class::REQUIRED_COUNT).to eq(3)
        expect(described_class::DWELL_TIME).to eq(30.minutes)

        described_class::REQUIRED_COUNT.times { |i| make_running_instance(i) }
        result = described_class.evaluate(version: version)
        expect(result[:eligible]).to be true
        expect(result[:required_count]).to eq(3)
      end
    end
  end

  # IMP-249aa98969bd — the dwell anchor must measure how long the qualifying
  # instances have been RUNNING the candidate digest, not how long ago they
  # last spoke. `evaluate` used to anchor on `min(last_heartbeat_at)`, so
  # clearing a 30-minute dwell required the stalest qualifying instance to
  # have been silent for 30 minutes while still `status: "running"` — ten
  # times InstanceStatusSensor::SILENT_THRESHOLD (3 minutes), the age at which
  # the platform already raises `system.instance_silent`. The gate was
  # anti-correlated with the health it exists to certify, and it failed in the
  # direction that PROMOTES on unhealthy evidence.
  #
  # BOTH halves below are required. An oracle that only tests the stale case
  # passes against the defect (failing closed on a meaningless anchor would
  # leave a healthy fleet permanently ineligible instead).
  describe "dwell anchors on time-running, not on silence" do
    def dwell_instance(idx, **kwargs)
      qualifying_instance(idx, prefix: "dwell-node", **kwargs)
    end

    context "a HEALTHY fleet running the candidate for longer than the dwell threshold" do
      it "is eligible" do
        described_class::REQUIRED_COUNT.times do |i|
          dwell_instance(i, heartbeat_at: 5.seconds.ago, first_seen_at: 90.minutes.ago)
        end

        result = described_class.evaluate(version: version)
        expect(result[:eligible]).to be true
        expect(result[:running_count]).to eq(described_class::REQUIRED_COUNT)
        expect(result[:dwell_time_minutes]).to be_within(1.0).of(90.0)
      end
    end

    context "a fleet that has been SILENT for longer than the dwell threshold" do
      it "does not satisfy dwell by staleness alone" do
        described_class::REQUIRED_COUNT.times do |i|
          dwell_instance(i, heartbeat_at: (described_class::DWELL_TIME + 5.minutes).ago,
                            first_seen_at: nil)
        end

        result = described_class.evaluate(version: version)
        expect(result[:eligible]).to be false
      end
    end

    context "when one long-running instance has gone silent" do
      it "refuses to promote on evidence the platform already treats as a fault" do
        described_class::REQUIRED_COUNT.times { |i| dwell_instance(i) }
        dwell_instance(99, heartbeat_at: 10.minutes.ago, first_seen_at: 90.minutes.ago)

        result = described_class.evaluate(version: version)
        expect(result[:eligible]).to be false
        expect(result[:reason]).to match(/silent/)
      end
    end

    context "when the newest qualifying instance has not yet dwelled" do
      it "anchors on the SHORTEST dwell across the qualifying set" do
        (described_class::REQUIRED_COUNT - 1).times { |i| dwell_instance(i, first_seen_at: 90.minutes.ago) }
        dwell_instance(50, first_seen_at: 2.minutes.ago)

        result = described_class.evaluate(version: version)
        expect(result[:eligible]).to be false
        expect(result[:reason]).to match(/dwell_time/)
        expect(result[:dwell_time_minutes]).to be_within(1.0).of(2.0)
      end
    end

    context "when a qualifying instance carries no first_seen_running_at stamp" do
      it "is ineligible — an unstamped instance is not evidence of dwell" do
        (described_class::REQUIRED_COUNT - 1).times { |i| dwell_instance(i) }
        dwell_instance(51, first_seen_at: nil)

        result = described_class.evaluate(version: version)
        expect(result[:eligible]).to be false
        expect(result[:reason]).to match(/first_seen_running_at/)
      end
    end
  end

  # Opt-in signature gate (DEFAULT OFF). When module_promotion_require_signature
  # resolves truthy through the same module -> account -> site cascade as the
  # other thresholds, a version whose erofs artifact carries no platform blob
  # signature (artifacts.erofs.cosign_blob_bundle_b64) is ineligible.
  describe ".signature_gate" do
    it "is inert by default" do
      expect(described_class.signature_gate(version)).to be_nil
    end

    it "refuses an unsigned version when required, naming the setting" do
      ::SiteSetting.set(described_class::REQUIRE_SIGNATURE_KEY, true, setting_type: "boolean")
      reason = described_class.signature_gate(version)
      expect(reason).to match(/no platform blob signature/)
      expect(reason).to include(described_class::REQUIRE_SIGNATURE_KEY)
    end

    it "passes a signed version when required" do
      ::SiteSetting.set(described_class::REQUIRE_SIGNATURE_KEY, true, setting_type: "boolean")
      version.update_columns(artifacts: { "erofs" => { "oci_digest" => digest, "cosign_blob_bundle_b64" => "YnVuZGxl" } })
      expect(described_class.signature_gate(version)).to be_nil
    end

    it "resolves through the module config layer too" do
      mod.update_columns(config: { described_class::REQUIRE_SIGNATURE_KEY => "true" })
      expect(described_class.signature_gate(version)).to match(/no platform blob signature/)
    end

    it "is consulted by .evaluate before any fleet evidence" do
      ::SiteSetting.set(described_class::REQUIRE_SIGNATURE_KEY, true, setting_type: "boolean")
      3.times { |i| qualifying_instance(i) }
      result = described_class.evaluate(version: version)
      expect(result[:eligible]).to be false
      expect(result[:reason]).to match(/no platform blob signature/)
    end
  end
end
