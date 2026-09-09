# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::Ai::Skills::CveRemediationOrchestrationExecutor do
  let(:account)   { create(:account) }
  let(:platform)  { create(:system_node_platform, account: account) }
  let(:category)  { create(:system_node_module_category, account: account) }
  let(:template)  { create(:system_node_template, account: account, node_platform: platform) }

  # A version is a rollout candidate only if it could actually be mounted:
  # NodeModuleVersion#rollback_usable? wants a recorded digest and an artifact
  # size clearing the publish floor (Environment campaign, increment 4b — the
  # decorative promotion_state label this used to set is gone).
  def usable_artifact(seed)
    { "erofs" => { "oci_digest" => "sha256:#{seed * 64}", "size" => 12_345_000 } }
  end

  let!(:openssl_mod) do
    create(:system_node_module, account: account, node_platform: platform,
           category: category, variety: "subscription", name: "openssl-base")
  end
  let!(:openssl_v1) do
    create(:system_node_module_version, node_module: openssl_mod, version_number: 1)
  end
  let(:repo) { create(:system_package_repository, account: account) }
  let!(:link) do
    create(:system_package_module_link,
           node_module: openssl_mod,
           package_repository: repo,
           package_name: "openssl",
           package_version: "3.1.3",
           architecture: "amd64")
  end
  let!(:cve) do
    ::System::Cve.create!(
      cve_id: "CVE-2026-50001",
      severity: "critical",
      affected_packages: [ { "name" => "openssl", "version" => "<3.1.4" } ],
      summary: "Test",
      feed_source: "TEST"
    )
  end
  let!(:exposure) do
    ::System::CveExposure.create!(
      cve: cve, node_module_version: openssl_v1, package_name: "openssl",
      package_version: "3.1.3", state: "open", detected_at: Time.current
    )
  end

  let(:executor) { described_class.new(account: account) }

  # IMP-594bfa5e1be5 — PackageModuleRefreshExecutor now really enqueues via
  # WorkerJobEnqueuer (raw LPUSH into the worker's Redis, which is LIVE on a
  # dev host). Stub the seam for the whole file so no example pushes a job.
  before { allow(::System::WorkerJobEnqueuer).to receive(:enqueue).and_return(SecureRandom.hex(12)) }

  describe ".descriptor" do
    it "advertises a security skill with cve_id input" do
      d = described_class.descriptor
      expect(d[:name]).to eq("cve_remediation_orchestration")
      expect(d[:category]).to eq("security")
      expect(d.dig(:inputs, :cve_id, :required)).to be true
    end
  end

  describe "#execute" do
    it "fails fast when the CVE doesn't exist" do
      r = executor.execute(cve_id: "CVE-2099-00001")
      expect(r[:success]).to be false
      expect(r[:error]).to match(/cve not found/)
    end

    it "triages the CVE and dispatches a package refresh for the linked module" do
      r = executor.execute(cve_id: "CVE-2026-50001", affected_module_ids: [ openssl_mod.id ])
      expect(r[:success]).to be true

      data = r[:data]
      expect(data[:cve_id]).to eq("CVE-2026-50001")
      expect(data[:refresh_dispatches]).not_to be_empty
      expect(data[:refresh_dispatches].first[:package_module_link_id]).to eq(link.id)
      expect(data[:refresh_dispatches].first[:ok]).to be true
      # IMP-594bfa5e1be5 — the refresh reaches the worker through the
      # WorkerJobEnqueuer seam (SystemPackageModuleRefreshJob itself is
      # worker-only and never resolves here), and `enqueued` is the
      # executor's evidence that it did.
      expect(data[:refresh_dispatches].first[:enqueued]).to be true
      expect(::System::WorkerJobEnqueuer).to have_received(:enqueue).with(
        hash_including(job_class: "SystemPackageModuleRefreshJob", args: [ link.id, false ])
      )
    end

    it "does not treat a refresh that queued nothing as remediation in flight" do
      # Pins the CONSUMER: #dispatched_module_ids must key on `enqueued`, not
      # `ok`. The real executor no longer produces ok:true/enqueued:false (it
      # fails when nothing is queued — see below), so the shape is stubbed
      # here; this example is what kills `select { |d| d[:ok] }`.
      allow_any_instance_of(::System::Ai::Skills::PackageModuleRefreshExecutor)
        .to receive(:execute)
        .and_return({ success: true, data: { enqueued: false, package_module_link_id: link.id } })

      r = executor.execute(cve_id: "CVE-2026-50001",
                           affected_module_ids: [ openssl_mod.id ],
                           exposure_ids: [ exposure.id ])

      expect(r.dig(:data, :refresh_dispatches).first[:ok]).to be true
      expect(r.dig(:data, :refresh_dispatches).first[:enqueued]).to be false
      expect(r.dig(:data, :remediation_dispatched)).to be false
      expect(r.dig(:data, :exposures_remediating)).to eq(0)
      expect(exposure.reload.state).to eq("open")
    end

    it "surfaces a refresh the worker seam could not queue as a failed dispatch" do
      # WorkerJobEnqueuer is fail-soft: Redis down => nil jid, no raise.
      allow(::System::WorkerJobEnqueuer).to receive(:enqueue).and_return(nil)

      r = executor.execute(cve_id: "CVE-2026-50001",
                           affected_module_ids: [ openssl_mod.id ],
                           exposure_ids: [ exposure.id ])

      dispatch = r.dig(:data, :refresh_dispatches).first
      expect(dispatch[:ok]).to be false
      expect(dispatch[:enqueued]).to be false
      expect(dispatch[:error]).to match(/could not be enqueued/)
      expect(r.dig(:data, :remediation_dispatched)).to be false
      expect(exposure.reload.state).to eq("open")
    end

    # IMP-79a808789805 — the rolling half of #dispatched_module_ids used to
    # count every plan that came back ok:true. RollingModuleUpgradeExecutor is
    # PLAN-ONLY (it returns `executed: false`; nothing in the platform moves
    # the module pointer from its plan — IMP-e8dc40813adb), so that flipped
    # every exposure of the module to `remediating` on the strength of work
    # nothing would do. `remediating` is a ONE-WAY exit from
    # CvePublishedSensor's `state: "open"` scope, so the alarm was not
    # delayed, it was dead. The oracle here is the ROW and the sensor, never
    # the returned hash: a non-empty rolling_upgrade_plans proves nothing
    # about suppression.
    context "when a rolling upgrade is planned but nothing executes it" do
      let(:sensor) { ::System::CveOps::Sensors::CvePublishedSensor.new(account: account) }
      let!(:blessed) do
        create(:system_node_module_version, node_module: openssl_mod,
               version_number: 2, artifacts: usable_artifact("b"))
      end
      let!(:node) { create(:system_node, account: account, node_template: template, name: "n1") }

      before do
        # IMP-594bfa5e1be5 — the refresh lane now really dispatches (it used
        # to be a silent no-op, which is the only reason these examples ever
        # saw openssl-base as "nothing in flight"). To test the ROLLING lane's
        # claim alone, the module must have no package link to refresh.
        link.destroy!
        openssl_mod.update!(current_version: openssl_v1)
        System::NodeModuleAssignment.create!(node: node, node_module: openssl_mod,
                                            enabled: true, priority: 0)
      end

      it "leaves the exposure open and visible to CvePublishedSensor when the plan covers running instances" do
        create(:system_node_instance, :running, node: node)

        r = executor.execute(cve_id: "CVE-2026-50001", exposure_ids: [ exposure.id ])

        # The ROW and the sensor first: these are the oracle.
        expect(exposure.reload.state).to eq("open")
        expect(sensor.sense.flat_map { |sig| sig.payload["exposure_ids"] }).to include(exposure.id)

        expect(r[:success]).to be true
        expect(r.dig(:data, :remediation_dispatched)).to be false
        expect(r.dig(:data, :exposures_remediating)).to eq(0)
        plan = r.dig(:data, :rolling_upgrade_plans).first
        expect(plan[:ok]).to be true
        # A POPULATED plan — this is the happy path (blessed fix, enabled
        # template assignment, a running instance), not the empty-fleet
        # case below. It still moves nothing.
        expect(plan[:total_instances]).to eq(1)
        expect(plan[:executed]).to be false
      end

      it "does not transition anything on a plan with total_instances: 0" do
        # No instance on the node: the executor still returns success, with
        # an empty affected set. An empty plan is even less evidence of work.
        r = executor.execute(cve_id: "CVE-2026-50001", exposure_ids: [ exposure.id ])

        expect(exposure.reload.state).to eq("open")
        expect(sensor.sense.flat_map { |sig| sig.payload["exposure_ids"] }).to include(exposure.id)

        expect(r.dig(:data, :remediation_dispatched)).to be false
        expect(r.dig(:data, :exposures_remediating)).to eq(0)
        plan = r.dig(:data, :rolling_upgrade_plans).first
        expect(plan[:ok]).to be true
        expect(plan[:total_instances]).to eq(0)
      end
    end

    it "produces a rolling upgrade plan when a newer blessed version exists" do
      link.destroy! # rolling lane only — see the context above (IMP-594bfa5e1be5)
      blessed = create(:system_node_module_version, node_module: openssl_mod,
                       version_number: 2, artifacts: usable_artifact("b"))
      openssl_mod.update!(current_version: openssl_v1)
      node = create(:system_node, account: account, node_template: template, name: "n1")
      System::NodeModuleAssignment.create!(node: node, node_module: openssl_mod, enabled: true, priority: 0)

      r = executor.execute(cve_id: "CVE-2026-50001", affected_module_ids: [ openssl_mod.id ])

      plans = r[:data][:rolling_upgrade_plans]
      expect(plans).not_to be_empty
      expect(plans.first[:node_module_id]).to eq(openssl_mod.id)
      expect(plans.first[:target_version_id]).to eq(blessed.id)
      # Positive control for the skip taxonomy below: a module that DID get a
      # plan must not be reported as skipped, and the run carries no reason.
      expect(r[:data][:skipped_reason]).to be_nil
      expect(r[:data][:skipped_modules]).to eq([])
      # A plan is not a dispatch (IMP-79a808789805): nothing executes it, so
      # the run must not claim remediation is in flight.
      expect(r[:data][:remediation_dispatched]).to be false
    end

    # IMP-9b8d774298d5 — "a fix exists but its version is not promoted" used to
    # be a SILENT skip: plan_rolling_upgrades did `next unless blessed`, perform
    # returned an unqualified success, and transition_exposures still ran, so
    # the lane asserted "response in flight" having dispatched nothing. Worse,
    # `remediating` is exactly the state CvePublishedSensor filters OUT
    # (`where(state: "open")`), so the false claim also silenced the sensor that
    # would otherwise keep re-raising the CVE every dedup window.
    #
    # nginx-base deliberately has NO PackageModuleLink, so dispatch_refreshes
    # contributes nothing and "nothing was dispatched" is reachable.
    context "when nothing could be dispatched for an exposed module" do
      let!(:nginx_mod) do
        create(:system_node_module, account: account, node_platform: platform,
               category: category, variety: "subscription", name: "nginx-base")
      end
      let!(:nginx_v1) do
        create(:system_node_module_version, node_module: nginx_mod, version_number: 1)
      end
      let!(:nginx_exposure) do
        ::System::CveExposure.create!(
          cve: cve, node_module_version: nginx_v1, package_name: "nginx",
          package_version: "1.0.0", state: "open", detected_at: Time.current
        )
      end

      before { nginx_mod.update!(current_version: nginx_v1) }

      it "leaves the exposure open instead of claiming remediation is in flight" do
        r = executor.execute(cve_id: "CVE-2026-50001",
                             affected_module_ids: [ nginx_mod.id ],
                             exposure_ids: [ nginx_exposure.id ])

        expect(r.dig(:data, :exposures_remediating)).to eq(0)
        expect(nginx_exposure.reload.state).to eq("open")
      end

      # IMP-79a808789805 — excluding a plan from remediated_module_ids must not
      # change the ENVELOPE of a mixed run: a successful plan IS an output an
      # operator can act on (the tutorial tells them to execute it by hand),
      # even though it is not evidence of work in flight. So a run that planned
      # for one module and skipped another stays a success and carries both.
      it "keeps a mixed run a success and carries the plan when another module is skipped" do
        link.destroy! # rolling lane only — see the context above (IMP-594bfa5e1be5)
        create(:system_node_module_version, node_module: nginx_mod,
               version_number: 2, artifacts: usable_artifact("c"))
        blessed = create(:system_node_module_version, node_module: openssl_mod,
                         version_number: 2, artifacts: usable_artifact("b"))
        openssl_mod.update!(current_version: openssl_v1)
        node = create(:system_node, account: account, node_template: template, name: "n-openssl")
        System::NodeModuleAssignment.create!(node: node, node_module: openssl_mod,
                                            enabled: true, priority: 0)

        r = executor.execute(cve_id: "CVE-2026-50001",
                             affected_module_ids: [ openssl_mod.id, nginx_mod.id ],
                             exposure_ids: [ exposure.id, nginx_exposure.id ])

        expect(r[:success]).to be true
        plan = r.dig(:data, :rolling_upgrade_plans).find { |p| p[:node_module_id] == openssl_mod.id }
        expect(plan).to be_present
        expect(plan[:ok]).to be true
        expect(plan[:target_version_id]).to eq(blessed.id)
        # The plan is still not a dispatch: neither exposure leaves `open`.
        expect(plan[:executed]).to be false
        expect(r.dig(:data, :remediation_dispatched)).to be false
        expect(r.dig(:data, :exposures_remediating)).to eq(0)
        expect(exposure.reload.state).to eq("open")
        expect(nginx_exposure.reload.state).to eq("open")
        # The skipped module is still named, with the actionable reason: its
        # usable v2 has no enabled assignment on any templated node.
        expect(r.dig(:data, :skipped_reason)).to eq("no_enabled_template_assignment")
        expect(r.dig(:data, :skipped_modules).map { |m| m[:node_module_id] })
          .to include(nginx_mod.id)
      end

      it "reports no_candidate_version when no newer version of any kind exists" do
        r = executor.execute(cve_id: "CVE-2026-50001", affected_module_ids: [ nginx_mod.id ])

        expect(r[:success]).to be true
        expect(r.dig(:data, :remediation_dispatched)).to be false
        expect(r.dig(:data, :skipped_reason)).to eq("no_candidate_version")
        expect(r.dig(:data, :skipped_modules).map { |m| m[:node_module_id] })
          .to eq([ nginx_mod.id ])
        expect(r.dig(:data, :skipped_modules).first[:candidate_version_id]).to be_nil
      end

      it "reports no_current_version when the module has no current version to compare against" do
        nginx_mod.update!(current_version: nil)
        r = executor.execute(cve_id: "CVE-2026-50001", affected_module_ids: [ nginx_mod.id ])

        expect(r[:success]).to be true
        expect(r.dig(:data, :skipped_reason)).to eq("no_current_version")
      end

      # A newer MOUNTABLE version is now a rollout candidate on its own: the
      # attestation the old lane demanded (promotion_state blessed/live) was a
      # label no node saw and no ordinary build ever carried, and its natural
      # replacement — "pinned in some environment" — is unreachable for a
      # version newer than current (the bottom pinned rung only takes what is
      # already current). What keeps the lane conservative is downstream: the
      # plan requires approval and nothing actuates it.
      it "plans for a newer usable version with no promotion of any kind" do
        candidate = create(:system_node_module_version, node_module: nginx_mod,
                           version_number: 2, artifacts: usable_artifact("c"))
        node = create(:system_node, account: account, node_template: template, name: "n-nginx")
        System::NodeModuleAssignment.create!(node: node, node_module: nginx_mod, enabled: true, priority: 0)

        r = executor.execute(cve_id: "CVE-2026-50001",
                             affected_module_ids: [ nginx_mod.id ],
                             exposure_ids: [ nginx_exposure.id ])

        expect(r[:success]).to be true
        plan = r.dig(:data, :rolling_upgrade_plans).find { |pl| pl[:node_module_id] == nginx_mod.id }
        expect(plan[:target_version_id]).to eq(candidate.id)
        expect(System::ModuleEnvironmentPin.where(node_module_id: nginx_mod.id)).to be_empty
        # Still not a dispatch: the exposure stays open until something executes.
        expect(plan[:executed]).to be false
        expect(nginx_exposure.reload.state).to eq("open")
      end

      # The admission test is NodeModuleVersion#rollback_usable?, the same one
      # the rollback path and the backlog sensor use. A newer row whose artifact
      # could not be mounted is not a fix, and must not be offered as one.
      it "does not offer a newer version whose artifact is unmountable" do
        create(:system_node_module_version, node_module: nginx_mod, version_number: 2, artifacts: {})
        node = create(:system_node, account: account, node_template: template, name: "n-nginx")
        System::NodeModuleAssignment.create!(node: node, node_module: nginx_mod, enabled: true, priority: 0)

        r = executor.execute(cve_id: "CVE-2026-50001", affected_module_ids: [ nginx_mod.id ])

        expect(r[:success]).to be true
        expect(r.dig(:data, :rolling_upgrade_plans)).to eq([])
        expect(r.dig(:data, :skipped_reason)).to eq("no_candidate_version")
      end

      it "ignores an unpromoted version OLDER than the module's current version" do
        # A stale `built` row from an earlier build must not be advertised as
        # the fix, nor fail the run: promoting it would be a downgrade.
        # The ordering key is created_at (inherited from
        # #newer_blessed_version_for), so the fixture is a row CREATED before
        # the current version regardless of its version_number.
        stale = create(:system_node_module_version, node_module: nginx_mod,
                       version_number: 2, artifacts: usable_artifact("c"))
        stale.update_column(:created_at, nginx_v1.created_at - 1.day)

        r = executor.execute(cve_id: "CVE-2026-50001", affected_module_ids: [ nginx_mod.id ])

        expect(r[:success]).to be true
        expect(r.dig(:data, :skipped_reason)).to eq("no_candidate_version")
      end

      it "reports no_enabled_template_assignment when a promoted fix exists but nothing runs it" do
        create(:system_node_module_version, node_module: nginx_mod,
               version_number: 2, artifacts: usable_artifact("b"))

        r = executor.execute(cve_id: "CVE-2026-50001",
                             affected_module_ids: [ nginx_mod.id ],
                             exposure_ids: [ nginx_exposure.id ])

        expect(r[:success]).to be true
        expect(r.dig(:data, :skipped_reason)).to eq("no_enabled_template_assignment")
        expect(nginx_exposure.reload.state).to eq("open")
      end

      it "prefers the higher-priority skip reason across modules" do
        # SKIP_REASON_PRIORITY ordering: an unassigned module (actionable) wins
        # over one with no candidate at all.
        create(:system_node_module_version, node_module: nginx_mod,
               version_number: 2, artifacts: usable_artifact("c"))
        other = create(:system_node_module, account: account, node_platform: platform,
                       category: category, variety: "subscription", name: "redis-base")
        other_v1 = create(:system_node_module_version, node_module: other, version_number: 1)
        other.update!(current_version: other_v1)

        r = executor.execute(cve_id: "CVE-2026-50001",
                             affected_module_ids: [ other.id, nginx_mod.id ])

        expect(r[:success]).to be true
        reasons = r.dig(:data, :skipped_modules).to_h { |m| [ m[:node_module_id], m[:reason] ] }
        expect(reasons[nginx_mod.id]).to eq("no_enabled_template_assignment")
        expect(reasons[other.id]).to eq("no_candidate_version")
        expect(r.dig(:data, :skipped_reason)).to eq("no_enabled_template_assignment")
      end

      it "names a resolved module id that matches no NodeModule in this account" do
        # Such an id used to fall out of find_each and appear in neither plans
        # nor skips, leaving a wholly empty run with no reason at all.
        ghost = SecureRandom.uuid
        r = executor.execute(cve_id: "CVE-2026-50001", affected_module_ids: [ ghost ])

        expect(r[:success]).to be true
        expect(r.dig(:data, :remediation_dispatched)).to be false
        expect(r.dig(:data, :skipped_reason)).to eq("module_not_found")
        expect(r.dig(:data, :skipped_modules).map { |m| m[:node_module_id] }).to eq([ ghost ])
      end

      it "does not count a rolling upgrade plan that reported failure as a dispatch" do
        create(:system_node_module_version, node_module: nginx_mod,
               version_number: 2, artifacts: usable_artifact("b"))
        node = create(:system_node, account: account, node_template: template, name: "n-nginx")
        System::NodeModuleAssignment.create!(node: node, node_module: nginx_mod,
                                            enabled: true, priority: 0)
        allow_any_instance_of(System::Ai::Skills::RollingModuleUpgradeExecutor)
          .to receive(:execute).and_return({ success: false, error: "boom" })

        r = executor.execute(cve_id: "CVE-2026-50001",
                             affected_module_ids: [ nginx_mod.id ],
                             exposure_ids: [ nginx_exposure.id ])

        expect(r.dig(:data, :rolling_upgrade_plans).first[:ok]).to be false
        expect(r.dig(:data, :remediation_dispatched)).to be false
        expect(r.dig(:data, :exposures_remediating)).to eq(0)
        expect(nginx_exposure.reload.state).to eq("open")
      end

      # THE load-bearing assertion for the transition_exposures rewrite. The
      # caller supplies exposure_ids for BOTH modules; only openssl-base gets
      # a dispatch. Restoring the old `if explicit_ids … elsif module_ids`
      # shape makes the explicit list bypass the module join and nginx-base's
      # exposure flips too — this example is what kills that mutant.
      #
      # IMP-79a808789805 — the dispatch is an executor reporting
      # `executed: true`. No shipped executor does (RollingModuleUpgrade
      # Executor is plan-only), so the stub below is the contract a future
      # actuator (IMP-e8dc40813adb) must honour: `executed` — not `ok`, not a
      # non-empty affected set — is the ONLY thing #dispatched_module_ids
      # may count for the rolling lane. It is also the positive control for
      # the plan-only context above: same fixtures, and the row DOES flip
      # once something evidences execution.
      it "lets an explicit exposure list NARROW the transition but never widen it" do
        # IMP-594bfa5e1be5 — rolling lane only, same as the siblings above.
        # With the link alive the refresh lane really dispatches for
        # openssl-base, which would satisfy every assertion below on its own
        # and silently retire the `executed`-vs-`ok` oracle this example
        # exists for (flip the stub to `executed: false` and it must go red).
        link.destroy!
        create(:system_node_module_version, node_module: openssl_mod,
               version_number: 2, artifacts: usable_artifact("b"))
        openssl_mod.update!(current_version: openssl_v1)
        node = create(:system_node, account: account, node_template: template, name: "n1")
        System::NodeModuleAssignment.create!(node: node, node_module: openssl_mod,
                                            enabled: true, priority: 0)
        allow_any_instance_of(System::Ai::Skills::RollingModuleUpgradeExecutor)
          .to receive(:execute)
          .and_return({ success: true, data: { total_instances: 1, executed: true } })

        r = executor.execute(cve_id: "CVE-2026-50001",
                             affected_module_ids: [ openssl_mod.id, nginx_mod.id ],
                             exposure_ids: [ exposure.id, nginx_exposure.id ])

        expect(r[:success]).to be true
        expect(r.dig(:data, :remediation_dispatched)).to be true
        expect(r.dig(:data, :exposures_remediating)).to eq(1)
        expect(exposure.reload.state).to eq("remediating")
        expect(nginx_exposure.reload.state).to eq("open")

        # skipped_modules tracks the ROLLING-UPGRADE lane specifically, so a
        # module that produced no plan is listed even on a run that dispatched
        # elsewhere. Keeping it listed is deliberate: a module can be
        # mid-rebuild AND blocked on promotion, and dropping the entry would
        # hide the second fact.
        by_module = r.dig(:data, :skipped_modules).index_by { |m| m[:node_module_id] }
        expect(by_module.keys).to eq([ nginx_mod.id ])
        expect(by_module[nginx_mod.id][:reason]).to eq("no_candidate_version")
        expect(r.dig(:data, :skipped_reason)).to eq("no_candidate_version")
      end
    end

    # IMP-7bba0413c36a — a keyword-only match has no version evidence and is
    # minted `suspected`. It is outside the default exposure selection (the
    # triage reads open/remediating rows) and outside #transition_exposures
    # (`unresolved` scope) even when a caller names it explicitly.
    describe "suspected (keyword-only) exposures" do
      let!(:qemu_mod) do
        create(:system_node_module, account: account, node_platform: platform,
               category: category, variety: "subscription", name: "qemu-guest-agent")
      end
      let!(:qemu_v1) { create(:system_node_module_version, node_module: qemu_mod, version_number: 1) }
      let!(:qemu_link) do
        create(:system_package_module_link,
               node_module: qemu_mod, package_repository: repo,
               package_name: "qemu-guest-agent", package_version: "8.0", architecture: "amd64")
      end
      let!(:suspected) do
        ::System::CveExposure.create!(
          cve: cve, node_module_version: qemu_v1, package_name: "qemu",
          package_version: nil, match_method: "keyword", state: "suspected", detected_at: Time.current
        )
      end

      it "leaves the suspected module out of the default (triage-derived) module set" do
        r = executor.execute(cve_id: "CVE-2026-50001")
        expect(r[:success]).to be true
        dispatched = r[:data][:refresh_dispatches].map { |d| d[:node_module_id] }
        expect(dispatched).to include(openssl_mod.id)
        expect(dispatched).not_to include(qemu_mod.id)
        expect(suspected.reload.state).to eq("suspected")
      end

      it "does not transition a suspected row even when the caller names it and its module explicitly" do
        r = executor.execute(cve_id: "CVE-2026-50001",
                             affected_module_ids: [ qemu_mod.id ], exposure_ids: [ suspected.id ])
        expect(r[:success]).to be true
        expect(r[:data][:refresh_dispatches].map { |d| d[:node_module_id] }).to include(qemu_mod.id)
        expect(r.dig(:data, :exposures_remediating)).to eq(0)
        expect(suspected.reload.state).to eq("suspected")
      end
    end

    it "is idempotent for already-remediating exposures" do
      exposure.update!(state: "remediating")
      r = executor.execute(cve_id: "CVE-2026-50001", exposure_ids: [ exposure.id ])
      expect(r[:success]).to be true
      expect(r[:data][:exposures_remediating]).to eq(0)
    end
  end
end
