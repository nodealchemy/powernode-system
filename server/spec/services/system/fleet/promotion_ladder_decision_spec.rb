# frozen_string_literal: true

require "rails_helper"

# IMP-c7d618b0b72f — pins the promotion-ladder decision recorded in
# docs/design/promotion-ladder-semantics.md (decision (c): the pre-pointer
# rungs `built`/`staging`/`blessed` are human-meaningful ELIGIBILITY labels;
# `live`/`retired` are HISTORICAL stamps and the fleet's actuator is
# NodeModule#current_version_id alone).
#
# Why this file exists at all, and why it does not stamp `blessed` by hand:
# every existing fixture for #newer_blessed_version_for creates its candidate
# with `promotion_state: "blessed"` directly (see
# cve_remediation_orchestration_executor_spec.rb:90, :255, :275, :301, :325).
# Those pass against a pipeline that has never produced a `blessed` row, so
# they can only ever prove the method's own arithmetic — never that its input
# set is reachable. The fixtures below are built through
# System::PackageBuildWebhookService, the CI-callback path that actually
# creates versions in production, so the promotion_state under test is the one
# the pipeline writes rather than the one the spec wishes for.
#
# Scope of that claim, stated rather than implied: it holds for the rung the
# PIPELINE owns. The prior state of each fixture (a stale `live` row, an
# ordinary `built` v1) is still set up directly, and the two positive examples
# walk the ladder with promote_to! — which is correct, because that IS the
# production mechanism for those rungs. What is never hand-stamped is the
# `blessed`/`built` outcome the pipeline itself decides.
RSpec.describe "promotion ladder reachability (IMP-c7d618b0b72f)" do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }

  let(:executor) { ::System::Ai::Skills::CveRemediationOrchestrationExecutor.new(account: account) }

  # The private lookup the CVE rolling-upgrade lane uses to answer "is there a
  # fix I may ship?" (cve_remediation_orchestration_executor.rb:423-431).
  def rollout_target_for(mod)
    executor.send(:newer_blessed_version_for, mod.reload)
  end

  # Runs the real CI-completion callback, the path that creates every
  # package-built version in production. Returns the created version.
  # NOTE: PackageBuildWebhookService#create_version also repoints
  # NodeModule#current_version_id at the row it just made
  # (package_build_webhook_service.rb:140) — publish auto-promotes the
  # pointer. That is load-bearing for the expectations below, not incidental.
  def build_version_through_webhook(mod, digest:)
    result = ::System::PackageBuildWebhookService.call(
      payload: {
        closure_id:   "closure-#{SecureRandom.hex(4)}",
        architecture: "amd64",
        modules: [ {
          module_id:          mod.id,
          file_spec:          [ "/usr/bin/thing" ],
          oci_ref:            "oci://registry.invalid/#{mod.id}:latest",
          oci_digest:         digest,
          fsverity_root_hash: "sha256:#{SecureRandom.hex(32)}"
        } ]
      }
    )
    raise "webhook build failed: #{result.errors.inspect}" unless result.success

    # NOT redundant with `result.success`. PackageBuildWebhookService#create_version
    # rescues RecordInvalid, logs, and returns nil WITHOUT appending to `errors`
    # (package_build_webhook_service.rb:142-145), and `call` derives success from
    # `errors.empty?` — so a version that failed to persist still reports
    # success:true. This helper would then hand back the module's UNCHANGED
    # current_version, and the stale-`live` example below would assert nil
    # against a fixture that built nothing at all: green, having tested nothing.
    raise "webhook reported success but created no version" unless result.versions_created == 1

    mod.reload.current_version
  end

  # A module carrying a stale `live` row with no live_at stamp and no
  # oci_digest — the shape observed on powernode-hub-frontend v20,
  # powernode-hub-worker v14 and reverse-proxy-traefik v13.
  #
  # Deliberately NOT attributed to a writer. AccountBootstrapService was the
  # obvious suspect and is not it: it writes a non-nil oci_digest
  # (account_bootstrap_service.rb:277) and only ever version_number 1
  # (:270), and its six baseline modules do not include any of the three
  # above. No enumerated writer produces this shape; see section 6 of
  # docs/design/promotion-ladder-semantics.md. The bound under test does not
  # depend on how the row got there, only that it is older than what is served.
  def module_with_stale_live_row(name:, auto_generated: false)
    mod, v1 = plain_module(name: name, auto_generated: auto_generated)
    v1.update!(promotion_state: "live")
    [ mod.reload, v1.reload ]
  end

  # A module with no ladder history at all — the shape of everything created
  # after the bootstrap era. Its v1 is an ordinary `built` row, so no ladder rung is occupied at all.
  # On the live control plane `runtime-go` (7 versions) and `sdwan-overlay`
  # (2 versions) are exactly this: every row `built`, nothing else, ever.
  def plain_module(name:, auto_generated: false)
    mod = create(:system_node_module, account: account, node_platform: platform,
                 category: category, variety: "subscription", name: name,
                 auto_generated: auto_generated)
    v1 = create(:system_node_module_version, node_module: mod, version_number: 1,
                promotion_state: "built", oci_digest: nil)
    mod.update!(current_version: v1, current_version_number: 1)
    [ mod.reload, v1 ]
  end

  describe "what the ordinary build pipeline writes" do
    it "lands an operator-authored module's version at `built`, never on a ladder rung" do
      mod, = module_with_stale_live_row(name: "ordinary-mod")

      v2 = build_version_through_webhook(mod, digest: "sha256:#{SecureRandom.hex(32)}")

      expect(mod.reload.auto_generated).to be false
      expect(v2.promotion_state).to eq("built")
      expect(v2.staging_baked_at).to be_nil
      expect(v2.blessed_at).to be_nil
    end

    it "lands an AUTO-GENERATED module's version at `blessed`, skipping the ladder entirely" do
      # package_build_webhook_service.rb:128 — `mod.auto_generated ? "blessed"
      # : "built"`. This is the ONE pipeline path that mints a `blessed` row,
      # and it does so as a CREATE, never as a promote_to! transition, so the
      # row carries no blessed_at stamp.
      mod, = module_with_stale_live_row(name: "autogen-mod", auto_generated: true)

      v2 = build_version_through_webhook(mod, digest: "sha256:#{SecureRandom.hex(32)}")

      expect(v2.promotion_state).to eq("blessed")
      expect(v2.blessed_at).to be_nil
    end

    it "moves the pointer to whatever it just built, so `current` is always the newest row" do
      # This is why the ladder cannot be gating anything today: the pointer
      # does not wait for it. Empirically true of every module sampled on the
      # live control plane (current_version_number == the highest version
      # number, 6/6 modules read 2026-09-01).
      mod, = module_with_stale_live_row(name: "pointer-mod")

      v2 = build_version_through_webhook(mod, digest: "sha256:#{SecureRandom.hex(32)}")

      expect(mod.reload.current_version_id).to eq(v2.id)
      expect(v2.version_number).to eq(mod.versions.maximum(:version_number))
    end
  end

  describe "#newer_blessed_version_for — the CVE lane's rollout gate" do
    it "finds NO rollout target for a module built through the ordinary path" do
      # The finding, pinned with a fixture the pipeline produced rather than
      # one the spec stamped: an operator-authored module accumulates `built`
      # rows forever, so the blessed/live filter matches nothing and the CVE
      # rolling-upgrade lane can never plan a shipment. The filter itself is
      # not the defect — restricting rollout to blessed material is defensible
      # conservatism. The defect is that no pipeline PRODUCES blessed material.
      #
      # A post-bootstrap module, so no `live` row from AccountBootstrapService
      # muddies the result: every row here was written by the pipeline.
      mod, = plain_module(name: "dead-lane-mod")
      build_version_through_webhook(mod, digest: "sha256:#{SecureRandom.hex(32)}")

      expect(mod.reload.versions.pluck(:promotion_state).uniq).to eq([ "built" ])
      expect(rollout_target_for(mod)).to be_nil
    end

    it "does NOT offer a stale bootstrap `live` row as the fix for a newer served version" do
      # RED before the recency bound. This is the production shape: v1 is the
      # bootstrap `live` row (no oci_digest, no live_at), the pipeline then
      # builds v2..vN and moves the pointer to the newest. `where.not(id:
      # current_version_id)` excludes only the served row, so the untouched
      # `live` v1 falls straight through the filter and is returned as "the
      # fix" — a downgrade to a row with no mountable artifact at all.
      #
      # Observed on the live control plane 2026-09-01:
      #   powernode-hub-frontend  current v26 -> would have offered v20 (live, oci_digest nil)
      #   reverse-proxy-traefik   current v16 -> would have offered v13 (live, oci_digest nil)
      #   powernode-hub-backend   current v87 -> would have offered v79 (live, 8 versions back)
      mod, v1 = module_with_stale_live_row(name: "downgrade-mod")
      v2 = build_version_through_webhook(mod, digest: "sha256:#{SecureRandom.hex(32)}")

      expect(v1.reload.promotion_state).to eq("live")
      expect(mod.reload.current_version_id).to eq(v2.id)

      expect(rollout_target_for(mod)).to be_nil
    end

    it "does offer a hand-promoted version that is genuinely NEWER than what is served" do
      # The other half of the asymmetry, and the only shape in which this lane
      # can legitimately fire: a build the publish path did NOT put on the
      # fleet (a withheld promote), which an operator then walks up the ladder.
      # The walk uses promote_to! — the real mechanism, and the only writer of
      # live_at (node_module_version.rb:116). Two such walks are visible on the
      # live control plane (hub-frontend v26 live_at 2026-08-31, hub-worker v23
      # live_at 2026-08-11), which is what proves the rungs are reachable by
      # hand even though nothing rests on them.
      mod, v1 = module_with_stale_live_row(name: "withheld-mod")
      v2 = build_version_through_webhook(mod, digest: "sha256:#{SecureRandom.hex(32)}")

      # Simulate the promote gate declining to move the pointer.
      mod.promote_to_version!(v1)
      expect(mod.reload.current_version_id).to eq(v1.id)

      v2.promote_to!("staging")
      v2.promote_to!("blessed")
      expect(v2.reload.blessed_at).to be_present

      expect(rollout_target_for(mod)).to eq(v2)
    end

    it "accepts a newer `live` version, not only a newer `blessed` one" do
      # Pins the `live` term of the blessed/live filter. Under the decision
      # `live` is a historical stamp, but a stamp on a version NEWER than the
      # served one still records a completed human promotion, so it stays an
      # acceptable rollout target. Without this example the filter could be
      # narrowed to `%w[blessed]` with every other example still green.
      mod, v1 = plain_module(name: "newer-live-mod")
      v2 = build_version_through_webhook(mod, digest: "sha256:#{SecureRandom.hex(32)}")

      mod.promote_to_version!(v1)
      v2.promote_to!("staging")
      v2.promote_to!("blessed")
      v2.promote_to!("live")
      expect(v2.reload.live_at).to be_present

      expect(rollout_target_for(mod)).to eq(v2)
    end
  end

  describe "the promotion sensor's input set" do
    it "is populated by the operator verbs and by nothing else, so it rests empty" do
      # ModulePromotionSensor scopes on promotion_state == "staging"
      # (module_promotion_sensor.rb:16). Nothing in the build/publish pipeline
      # writes that value, so the only producer is a human pausing mid-walk on
      # promote_to!. A walk done in one sitting leaves no row behind, which is
      # why the live control plane shows 0 staging rows across every module
      # sampled — not because the rung is unreachable, but because nobody rests
      # on it.
      mod, = module_with_stale_live_row(name: "sensor-input-mod")
      v2 = build_version_through_webhook(mod, digest: "sha256:#{SecureRandom.hex(32)}")

      staged = -> { ::System::NodeModuleVersion.joins(node_module: :account)
                       .where(accounts: { id: account.id }, promotion_state: "staging") }

      expect(staged.call).to be_empty

      v2.promote_to!("staging")

      expect(staged.call).to contain_exactly(v2)
      expect(v2.reload.staging_baked_at).to be_present
    end
  end
end
