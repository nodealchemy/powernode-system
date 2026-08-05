# frozen_string_literal: true

require "rails_helper"

# Campaign 019f5885 inc10 — System::ModuleBuildParityService. Structurally
# compares the Gitea-authoritative `:<sha>` artifact against the shadow
# native `:native-<sha>` artifact for every module in a shadow batch, using
# a stubbable LocalParityAdapter so no real registry/oras/fsck.erofs is
# needed in the suite.
RSpec.describe System::ModuleBuildParityService do
  let(:account) { create(:account) }

  let(:local_adapter) { System::ModuleBuildParityService::LocalParityAdapter.new }

  before do
    allow(::System::DiskImageRegistryConfig).to receive(:registry_host).and_return("registry.example.com")
    System::ModuleBuildParityService.adapter = local_adapter
  end

  after { System::ModuleBuildParityService.reset! }

  def create_module(name)
    create(:system_node_module, account: account, name: name, gitea_repo_full_name: "powernode/#{name}")
  end

  def shadow_batch(modules:, head_sha: "headsha1234567")
    plan = modules.map { |m| { module: m.name, oci_ref: "native-#{head_sha[0, 7]}" } }
    System::ModuleBuildBatch.create_for(
      account: account, plan: plan, trigger: "push", base_sha: "base0000", head_sha: head_sha, shadow: true
    )
  end

  def refs_for(mod, head_sha: "headsha1234567")
    gitea_tag  = head_sha[0, 7]
    native_tag = "native-#{gitea_tag}"
    [
      "registry.example.com/powernode/#{mod.name}:#{gitea_tag}",
      "registry.example.com/powernode/#{mod.name}:#{native_tag}"
    ]
  end

  describe "#compare! / .compare!" do
    it "rejects a non-shadow batch" do
      mod = create_module("mod-a")
      plan = [ { module: mod.name, oci_ref: "abc1234" } ]
      batch = System::ModuleBuildBatch.create_for(account: account, plan: plan, trigger: "push",
                                                   base_sha: "b", head_sha: "headsha1234567", shadow: false)

      result = described_class.compare!(batch: batch)

      expect(result.ok?).to be false
      expect(result.error).to include("not a shadow batch")
    end

    it "marks a module ok and emits system.module_build_parity_ok when artifacts are identical" do
      mod = create_module("mod-identical")
      batch = shadow_batch(modules: [ mod ])
      gitea_ref, native_ref = refs_for(mod)
      local_adapter.stub!(ref_a: gitea_ref, ref_b: native_ref,
                           result: { identical: true, added: [], removed: [], changed: [] })

      expect {
        result = described_class.compare!(batch: batch)
        @result = result
      }.to change { System::FleetEvent.where(account: account, kind: "system.module_build_parity_ok").count }.by(1)

      expect(@result.ok?).to be true
      mod_result = @result.results.find { |r| r.module == mod.name }
      expect(mod_result.status).to eq("ok")
      expect(mod_result.identical).to be true

      event = System::FleetEvent.where(kind: "system.module_build_parity_ok").last
      expect(event.severity).to eq("low")
      expect(event.payload["module"]).to eq(mod.name)
      expect(event.payload["batch_id"]).to eq(batch.id)
    end

    it "marks a module failed and emits system.module_build_parity_failed (severity high) on divergence" do
      mod = create_module("mod-diverges")
      batch = shadow_batch(modules: [ mod ])
      gitea_ref, native_ref = refs_for(mod)
      local_adapter.stub!(ref_a: gitea_ref, ref_b: native_ref,
                           result: { identical: false, added: [ "/etc/new.conf" ], removed: [], changed: [ "/etc/x.conf" ] })

      expect {
        @result = described_class.compare!(batch: batch)
      }.to change { System::FleetEvent.where(account: account, kind: "system.module_build_parity_failed").count }.by(1)

      mod_result = @result.results.find { |r| r.module == mod.name }
      expect(mod_result.status).to eq("failed")
      expect(mod_result.identical).to be false
      expect(mod_result.diff_summary).to eq("added" => [ "/etc/new.conf" ], "removed" => [], "changed" => [ "/etc/x.conf" ])

      event = System::FleetEvent.where(kind: "system.module_build_parity_failed").last
      expect(event.severity).to eq("high")
      expect(event.payload["added"]).to eq([ "/etc/new.conf" ])
    end

    it "skips a waivered module — no adapter call, no event, status waived" do
      mod = create_module("vector")
      batch = shadow_batch(modules: [ mod ])
      # Default waiver list includes "vector" (inc5 live-repo-hook module).
      expect(local_adapter).not_to receive(:diff)

      result = described_class.compare!(batch: batch)

      mod_result = result.results.find { |r| r.module == "vector" }
      expect(mod_result.status).to eq("waived")
      expect(System::FleetEvent.where(kind: %w[system.module_build_parity_ok system.module_build_parity_failed]).count).to eq(0)
    end

    it "honors an operator-configured waiver list (SiteSetting overrides the default)" do
      mod = create_module("some-custom-module")
      SiteSetting.set("system.module_builds.parity_waivers", [ "some-custom-module" ].to_json, setting_type: "json")
      batch = shadow_batch(modules: [ mod ])
      expect(local_adapter).not_to receive(:diff)

      result = described_class.compare!(batch: batch)

      expect(result.results.first.status).to eq("waived")
    end

    it "a SiteSetting-configured waiver list no longer waives modules it excludes" do
      mod = create_module("vector") # in the DEFAULT waiver list
      SiteSetting.set("system.module_builds.parity_waivers", [ "some-other-module" ].to_json, setting_type: "json")
      batch = shadow_batch(modules: [ mod ])
      gitea_ref, native_ref = refs_for(mod)
      local_adapter.stub!(ref_a: gitea_ref, ref_b: native_ref, result: { identical: true, added: [], removed: [], changed: [] })

      result = described_class.compare!(batch: batch)

      expect(result.results.first.status).to eq("ok") # not waived — the operator's list won
    end

    it "records an error result (no event) when the adapter reports an error" do
      mod = create_module("mod-broken")
      batch = shadow_batch(modules: [ mod ])
      gitea_ref, native_ref = refs_for(mod)
      local_adapter.stub!(ref_a: gitea_ref, ref_b: native_ref, result: { error: "oras pull 404" })

      result = described_class.compare!(batch: batch)

      mod_result = result.results.first
      expect(mod_result.status).to eq("error")
      expect(mod_result.error).to eq("oras pull 404")
      expect(System::FleetEvent.where(kind: %w[system.module_build_parity_ok system.module_build_parity_failed]).count).to eq(0)
    end

    it "records an error result when the NodeModule can no longer be resolved" do
      batch = System::ModuleBuildBatch.create_for(
        account: account, plan: [ { module: "ghost-module", oci_ref: "native-abc1234" } ],
        trigger: "push", base_sha: "b", head_sha: "headsha1234567", shadow: true
      )

      result = described_class.compare!(batch: batch)

      expect(result.results.first.status).to eq("error")
      expect(result.results.first.error).to include("not found")
    end

    it "persists per-module results onto batch.metadata['parity']" do
      good = create_module("mod-good")
      bad  = create_module("mod-bad")
      batch = shadow_batch(modules: [ good, bad ])
      good_refs = refs_for(good)
      bad_refs  = refs_for(bad)
      local_adapter.stub!(ref_a: good_refs[0], ref_b: good_refs[1],
                           result: { identical: true, added: [], removed: [], changed: [] })
      local_adapter.stub!(ref_a: bad_refs[0], ref_b: bad_refs[1],
                           result: { identical: false, added: [ "/x" ], removed: [], changed: [] })

      described_class.compare!(batch: batch)

      parity = batch.reload.metadata["parity"]
      expect(parity["mod-good"]["status"]).to eq("ok")
      expect(parity["mod-bad"]["status"]).to eq("failed")
      expect(parity["mod-bad"]["diff_summary"]).to eq("added" => [ "/x" ], "removed" => [], "changed" => [])
    end

    it "never touches NativeModuleBuildOrchestrator's own metadata['plan']/metadata['modules'] bookkeeping" do
      mod = create_module("mod-a")
      batch = shadow_batch(modules: [ mod ])
      original_plan = batch.metadata["plan"]

      described_class.compare!(batch: batch)

      expect(batch.reload.metadata["plan"]).to eq(original_plan)
    end
  end

  describe System::ModuleBuildParityService::LocalParityAdapter do
    # IMP-b260339283bb: the default output now carries `stub: true`. It always
    # WAS a fabricated verdict — an unconditional "identical" without touching
    # a registry — the marker just makes that legible to the persist gate.
    # Asserting the marker rather than dropping the example, because "the
    # default is a pass" is exactly the property that makes the gate necessary.
    it "returns an identical result by default when nothing is stubbed, marked as a stub" do
      adapter = described_class.new
      expect(adapter.diff(ref_a: "a", ref_b: "b"))
        .to eq(identical: true, added: [], removed: [], changed: [], stub: true)
    end

    it "leaves a caller-supplied stub! override unmarked" do
      adapter = described_class.new
      adapter.stub!(ref_a: "a", ref_b: "b", result: { identical: false, added: %w[x], removed: [], changed: [] })

      expect(adapter.diff(ref_a: "a", ref_b: "b")).not_to have_key(:stub)
    end
  end

  # IMP-b260339283bb — the same unguarded stub-adapter override that detonated
  # on 2026-07-16, on this service's call path.
  #
  # LocalParityAdapter#diff returns `identical: true` UNCONDITIONALLY without
  # contacting a registry: a fabricated PASS. compare! then writes that verdict
  # into batch.metadata["parity"], which is the record operators read to decide
  # whether a native build matches the Gitea-authoritative artifact. Selection
  # is an ENV override (POWERNODE_PARITY_MODE) with no environment guard, and
  # `adapter=` is public.
  #
  # WHICH ENVIRONMENTS THE PERSIST GATE ADMITS: test, and ONLY test. It refuses
  # in development, staging, production and any custom env. Deliberately NOT
  # "outside production" — the 2026-07-16 detonation was in DEVELOPMENT
  # (RAILS_ENV=development, where local IS the default adapter), so a
  # production-scoped guard would have permitted the exact incident it exists
  # to prevent. A fabricated parity verdict has no legitimate purpose outside a
  # spec run.
  describe "refuses the fabricating stub adapter outside test (IMP-b260339283bb)" do
    def in_env!(name)
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new(name))
    end

    let(:mod) { create_module("mod-parity") }
    let(:batch) { shadow_batch(modules: [ mod ]) }

    # ── Selection-time gate (mirrors 54cf1fdc) ────────────────────────────
    describe "adapter selection" do
      before { System::ModuleBuildParityService.reset! }

      it "refuses POWERNODE_PARITY_MODE=local in production, naming the misconfiguration" do
        in_env!("production")
        stub_const("ENV", ENV.to_h.merge("POWERNODE_PARITY_MODE" => "local"))

        expect { System::ModuleBuildParityService.adapter }
          .to raise_error(System::ModuleBuildParityService::ParityError, /fabricat/i)
      end

      it "still selects the oras adapter in production by default" do
        in_env!("production")
        stub_const("ENV", ENV.to_h.except("POWERNODE_PARITY_MODE"))

        expect(System::ModuleBuildParityService.adapter)
          .to be_a(System::ModuleBuildParityService::OrasParityAdapter)
      end

      # Selection must stay permissive outside production or every dev flow and
      # every spec breaks. The persist gate is what catches development.
      it "still selects the local adapter outside production" do
        in_env!("development")
        stub_const("ENV", ENV.to_h.except("POWERNODE_PARITY_MODE"))

        expect(System::ModuleBuildParityService.adapter)
          .to be_a(System::ModuleBuildParityService::LocalParityAdapter)
      end
    end

    # ── Persist-time gate (mirrors ba116eac — the one that matters) ───────
    describe "persisting a fabricated verdict" do
      it "refuses in production even when the adapter is injected directly" do
        in_env!("production")

        result = System::ModuleBuildParityService.compare!(batch: batch)

        expect(result.ok?).to be false
        expect(result.error).to match(/fabricated stub parity/i)
      end

      # THE 2026-07-16 LESSON. A `unless Rails.env.production?` guard would
      # permit exactly this.
      it "refuses in DEVELOPMENT too — the environment that actually detonated" do
        in_env!("development")

        result = System::ModuleBuildParityService.compare!(batch: batch)

        expect(result.ok?).to be false
        expect(result.error).to match(/fabricated stub parity/i)
      end

      it "writes no parity metadata when it refuses" do
        in_env!("development")

        System::ModuleBuildParityService.compare!(batch: batch)

        expect(batch.reload.metadata).not_to have_key("parity")
      end

      it "names the environment and the adapter in the refusal" do
        in_env!("staging")

        result = System::ModuleBuildParityService.compare!(batch: batch)

        expect(result.error).to include("staging")
        expect(result.error).to include("LocalParityAdapter")
      end

      # The escape hatch, exactly as the shipped sibling kept it: a
      # caller-supplied fixture is real-shaped and carries no marker, so a dev
      # flow that genuinely needs a recorded comparison still works.
      it "still records a caller-supplied stub! override outside test" do
        in_env!("development")
        gitea_ref, native_ref = refs_for(mod)
        local_adapter.stub!(ref_a: gitea_ref, ref_b: native_ref,
                            result: { identical: true, added: [], removed: [], changed: [] })

        result = System::ModuleBuildParityService.compare!(batch: batch)

        expect(result.ok?).to be true
        expect(batch.reload.metadata["parity"][mod.name]["status"]).to eq("ok")
      end

      it "records normally in test, where a fabricated verdict is harmless" do
        result = System::ModuleBuildParityService.compare!(batch: batch)

        expect(result.ok?).to be true
        expect(batch.reload.metadata["parity"][mod.name]["status"]).to eq("ok")
      end
    end
  end
end
