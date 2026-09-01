# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::Ai::Skills::CveRemediationOrchestrationExecutor do
  let(:account)   { create(:account) }
  let(:platform)  { create(:system_node_platform, account: account) }
  let(:category)  { create(:system_node_module_category, account: account) }
  let(:template)  { create(:system_node_template, account: account, node_platform: platform) }

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
      # PackageModuleRefreshExecutor returns success whether or not it queued
      # anything, and SystemPackageModuleRefreshJob is defined only in
      # worker/, which the Rails server does not autoload. So `ok` is true and
      # `enqueued` is false, and only the latter may count as remediation.
      expect(data[:refresh_dispatches].first[:enqueued]).to be false
    end

    it "does not treat a refresh that queued nothing as remediation in flight" do
      r = executor.execute(cve_id: "CVE-2026-50001",
                           affected_module_ids: [ openssl_mod.id ],
                           exposure_ids: [ exposure.id ])

      expect(r.dig(:data, :refresh_dispatches).first[:ok]).to be true
      expect(r.dig(:data, :remediation_dispatched)).to be false
      expect(r.dig(:data, :exposures_remediating)).to eq(0)
      expect(exposure.reload.state).to eq("open")
    end

    it "transitions named exposures to remediating once a rolling upgrade is planned" do
      create(:system_node_module_version, node_module: openssl_mod,
             version_number: 2, promotion_state: "blessed")
      openssl_mod.update!(current_version: openssl_v1)
      node = create(:system_node, account: account, node_template: template, name: "n1")
      System::NodeModuleAssignment.create!(node: node, node_module: openssl_mod,
                                          enabled: true, priority: 0)

      r = executor.execute(cve_id: "CVE-2026-50001", exposure_ids: [ exposure.id ])

      expect(r.dig(:data, :remediation_dispatched)).to be true
      expect(exposure.reload.state).to eq("remediating")
    end

    it "produces a rolling upgrade plan when a newer blessed version exists" do
      blessed = create(:system_node_module_version, node_module: openssl_mod,
                       version_number: 2, promotion_state: "blessed")
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
      expect(r[:data][:remediation_dispatched]).to be true
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

      it "fails loudly and names the module + unpromoted candidate when a fix is built but not promoted" do
        candidate = create(:system_node_module_version, node_module: nginx_mod,
                           version_number: 2, promotion_state: "built")

        r = executor.execute(cve_id: "CVE-2026-50001",
                             affected_module_ids: [ nginx_mod.id ],
                             exposure_ids: [ nginx_exposure.id ])

        expect(r[:success]).to be false
        # The message is the operator surface, so it is the oracle. Asserting
        # the candidate's id (obtainable only from the interpolation) rather
        # than the word "built", which the surrounding literal also contains.
        expect(r[:error]).to include("nginx-base")
        expect(r[:error]).to include(candidate.id)
        expect(r[:error]).to include("version 2 is built")

        # A bare failure — no :data. #failure's **extra is the composition
        # runner's rollback seam, not a diagnostics channel.
        expect(r).not_to have_key(:data)

        # The blocked lane must not fake in-flight response.
        expect(nginx_exposure.reload.state).to eq("open")
      end

      it "names the LEGAL next promotion rung, not blessed, for a built candidate" do
        create(:system_node_module_version, node_module: nginx_mod,
               version_number: 2, promotion_state: "built")

        r = executor.execute(cve_id: "CVE-2026-50001", affected_module_ids: [ nginx_mod.id ])

        # promote_to!("blessed") from "built" raises InvalidTransition, so an
        # instruction to promote straight to blessed is unfollowable.
        expect(r[:error]).to include("next promotion step is staging")
        expect(r[:error]).not_to include("promote it to blessed")
      end

      it "treats a staging candidate as promotable and points at blessed" do
        create(:system_node_module_version, node_module: nginx_mod,
               version_number: 2, promotion_state: "staging")

        r = executor.execute(cve_id: "CVE-2026-50001", affected_module_ids: [ nginx_mod.id ])

        expect(r[:success]).to be false
        expect(r[:error]).to include("version 2 is staging")
        expect(r[:error]).to include("next promotion step is blessed")
      end

      it "does not claim promotion releases the fix" do
        create(:system_node_module_version, node_module: nginx_mod,
               version_number: 2, promotion_state: "built")

        r = executor.execute(cve_id: "CVE-2026-50001", affected_module_ids: [ nginx_mod.id ])

        # Promotion advances promotion_state only; it does not move
        # NodeModule#current_version_id. IMP-65bea54e4081 removed exactly this
        # fabrication from the promote tool's description — do not re-mint it.
        expect(r[:error]).to include("it does not change which version the fleet serves")
        expect(r[:error]).not_to match(/release the fix:/)
      end

      it "ignores an unpromoted version OLDER than the module's current version" do
        # A stale `built` row from an earlier build must not be advertised as
        # the fix, nor fail the run: promoting it would be a downgrade.
        # The ordering key is created_at (inherited from
        # #newer_blessed_version_for), so the fixture is a row CREATED before
        # the current version regardless of its version_number.
        stale = create(:system_node_module_version, node_module: nginx_mod,
                       version_number: 2, promotion_state: "built")
        stale.update_column(:created_at, nginx_v1.created_at - 1.day)

        r = executor.execute(cve_id: "CVE-2026-50001", affected_module_ids: [ nginx_mod.id ])

        expect(r[:success]).to be true
        expect(r.dig(:data, :skipped_reason)).to eq("no_candidate_version")
      end

      it "reports no_enabled_template_assignment when a promoted fix exists but nothing runs it" do
        create(:system_node_module_version, node_module: nginx_mod,
               version_number: 2, promotion_state: "blessed")

        r = executor.execute(cve_id: "CVE-2026-50001",
                             affected_module_ids: [ nginx_mod.id ],
                             exposure_ids: [ nginx_exposure.id ])

        expect(r[:success]).to be true
        expect(r.dig(:data, :skipped_reason)).to eq("no_enabled_template_assignment")
        expect(nginx_exposure.reload.state).to eq("open")
      end

      it "prefers the promotion-blocked reason over a lower-priority skip" do
        # SKIP_REASON_PRIORITY ordering: an actionable promotion block must win
        # over a module that is merely unassigned.
        create(:system_node_module_version, node_module: nginx_mod,
               version_number: 2, promotion_state: "built")
        other = create(:system_node_module, account: account, node_platform: platform,
                       category: category, variety: "subscription", name: "redis-base")
        other_v1 = create(:system_node_module_version, node_module: other, version_number: 1)
        create(:system_node_module_version, node_module: other, version_number: 2,
               promotion_state: "blessed")
        other.update!(current_version: other_v1)

        r = executor.execute(cve_id: "CVE-2026-50001",
                             affected_module_ids: [ other.id, nginx_mod.id ])

        reasons = r[:error] ? nil : r.dig(:data, :skipped_modules).map { |m| m[:reason] }
        expect(reasons).to be_nil, "expected the promotion block to fail the run, got #{reasons.inspect}"
        expect(r[:success]).to be false
        expect(r[:error]).to include("nginx-base")
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
               version_number: 2, promotion_state: "blessed")
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
      it "lets an explicit exposure list NARROW the transition but never widen it" do
        create(:system_node_module_version, node_module: openssl_mod,
               version_number: 2, promotion_state: "blessed")
        openssl_mod.update!(current_version: openssl_v1)
        node = create(:system_node, account: account, node_template: template, name: "n1")
        System::NodeModuleAssignment.create!(node: node, node_module: openssl_mod,
                                            enabled: true, priority: 0)

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

    it "is idempotent for already-remediating exposures" do
      exposure.update!(state: "remediating")
      r = executor.execute(cve_id: "CVE-2026-50001", exposure_ids: [ exposure.id ])
      expect(r[:success]).to be true
      expect(r[:data][:exposures_remediating]).to eq(0)
    end
  end
end
