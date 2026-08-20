# frozen_string_literal: true

require "rails_helper"

# IMP-57e9a90598ee — the driver that gives Sdwan::OvnDeployment's AASM events
# their first production caller.
#
# Before this, start_bootstrap! / mark_active! / mark_degraded! / readopt! were
# called from exactly one place in the tree: db/seeds/smoke_test_ovn_models.rb.
# Both creation paths (Sdwan::Executors::CreateOvnDeployment and
# SdwanOvnComposeTopologyExecutor) wrote a row at the "pending" default and
# stopped, while TopologyCompiler.ovn_control_for and .ovn_nb_plan_for both
# required "active" — so the agent's OvnControllerApplier and ShellOvnNbApplier
# received nil for every account, forever.
#
# ORACLE DISCIPLINE is the whole point of this spec file. The reconciler must
# never transition on the strength of "a row exists", "a create succeeded", or
# "time passed". Every forward transition traces to a measured observation, and
# an ABSENT observation must leave the state exactly where it was.
RSpec.describe Sdwan::Ovn::DeploymentReconciler do
  let(:account)       { create(:account) }
  let(:node_template) { create(:system_node_template, account: account) }
  let(:node)          { create(:system_node, account: account, node_template: node_template) }
  let(:instance) do
    create(:system_node_instance, node: node, status: "running", network_profile: "heavyweight")
  end

  let!(:deployment) { create(:sdwan_ovn_deployment, account: account, status: "pending") }

  # Probe verdicts, built through the real result class so a change to its
  # shape breaks here rather than silently passing a stubbed double.
  def confirmed
    Sdwan::Ovn::NbProbe::Result.confirmed(databases: %w[OVN_Northbound _Server])
  end

  def probe_failed(error = "Connection refused")
    Sdwan::Ovn::NbProbe::Result.failed(error: error)
  end

  def not_measured(reason = "tls_probe_unsupported")
    Sdwan::Ovn::NbProbe::Result.not_measured(reason: reason)
  end

  def stub_probe(result)
    allow(Sdwan::Ovn::NbProbe).to receive(:probe_cached).and_return(result)
  end

  def reconcile!(nb_observation: nil, via: instance)
    described_class.reconcile!(instance: via, nb_observation: nb_observation)
  end

  # Shape mirrors agent/internal/sdwan/ovn_nb_applier.go ObservedOvnNbState
  # as serialized into the heartbeat's `sdwan_ovn_state` block.
  def observation(applied:, planned:, last_error: nil, cache_hit: nil, deployment_id: deployment.id)
    {
      "deployment_id"    => deployment_id,
      "nb_db_endpoint"   => deployment.nb_db_endpoint,
      "plan_commands"    => planned,
      "applied_commands" => applied,
      "compiled_at"      => 1.minute.ago.utc.iso8601,
      "last_replay_at"   => Time.current.utc.iso8601,
      "last_error"       => last_error,
      "cache_hit"        => cache_hit
    }.compact
  end

  describe "leaving pending" do
    it "starts bootstrapping once the endpoints are asserted" do
      stub_probe(not_measured)

      reconcile!

      expect(deployment.reload.status).to eq("bootstrapping")
      expect(deployment.bootstrapped_at).to be_present
    end

    it "stays pending when the endpoints are blank — there is nothing to observe" do
      deployment.update_columns(nb_db_endpoint: nil, sb_db_endpoint: nil)
      stub_probe(not_measured)

      reconcile!

      expect(deployment.reload.status).to eq("pending")
    end

    it "activates in the same pass when the probe confirms an OVN Northbound DB" do
      stub_probe(confirmed)

      reconcile!

      expect(deployment.reload.status).to eq("active")
      expect(deployment.activated_at).to be_present
    end
  end

  describe "bootstrapping → active is driven by ground truth, never by self-report" do
    before { deployment.update_columns(status: "bootstrapping", bootstrapped_at: 1.hour.ago) }

    it "activates when the probe confirms" do
      stub_probe(confirmed)

      reconcile!

      expect(deployment.reload.status).to eq("active")
    end

    it "activates when a chassis reports a full successful NB replay" do
      stub_probe(not_measured)

      reconcile!(nb_observation: observation(applied: 5, planned: 5))

      expect(deployment.reload.status).to eq("active")
    end

    it "activates on a cache-hit full success — the applier only caches after a real replay" do
      # ShellOvnNbApplier populates its short-circuit cache exclusively from a
      # completed successful replay and clears it on failure/empty-plan, so a
      # cache_hit observation implies an executed full success earlier in the
      # same agent process. Refusing it would strand a deployment whose one
      # executed-success heartbeat was lost.
      stub_probe(not_measured)

      reconcile!(nb_observation: observation(applied: 5, planned: 5, cache_hit: true))

      expect(deployment.reload.status).to eq("active")
    end

    it "stays bootstrapping when the probe measured a failure" do
      stub_probe(probe_failed)

      reconcile!

      # NOT degraded: this deployment has never once been observed healthy, so
      # "degraded" would assert a recovery path that was never established.
      expect(deployment.reload.status).to eq("bootstrapping")
    end

    it "stays bootstrapping when the probe could not measure anything" do
      stub_probe(not_measured)

      reconcile!

      expect(deployment.reload.status).to eq("bootstrapping")
    end

    it "stays bootstrapping on a failed chassis replay — never active, never degraded" do
      stub_probe(not_measured)

      reconcile!(nb_observation: observation(applied: 2, planned: 5, last_error: "ovn-nbctl: connection timed out"))

      expect(deployment.reload.status).to eq("bootstrapping")
    end

    it "does not activate merely because the row is old" do
      deployment.update_columns(bootstrapped_at: 30.days.ago, created_at: 30.days.ago)
      stub_probe(not_measured)

      reconcile!

      expect(deployment.reload.status).to eq("bootstrapping")
    end

    it "does not activate on an observation about a different deployment id" do
      stub_probe(not_measured)

      reconcile!(nb_observation: observation(applied: 5, planned: 5, deployment_id: SecureRandom.uuid))

      expect(deployment.reload.status).to eq("bootstrapping")
    end
  end

  describe "the chassis NB replay observation owns degraded / readopt" do
    before { deployment.update_columns(status: "active", activated_at: 1.hour.ago) }

    it "degrades when the on-host replay reported an error" do
      stub_probe(not_measured)

      reconcile!(nb_observation: observation(applied: 2, planned: 5, last_error: "ovn-nbctl: connection timed out"))

      expect(deployment.reload.status).to eq("degraded")
      expect(deployment.degraded_at).to be_present
    end

    it "degrades on a partial replay even with no error string" do
      stub_probe(not_measured)

      reconcile!(nb_observation: observation(applied: 2, planned: 5))

      expect(deployment.reload.status).to eq("degraded")
    end

    it "readopts a degraded deployment when the SAME chassis reports a full replay" do
      stub_probe(not_measured)
      reconcile!(nb_observation: observation(applied: 2, planned: 5, last_error: "no route to host"))
      expect(deployment.reload.status).to eq("degraded")

      reconcile!(nb_observation: observation(applied: 5, planned: 5))

      expect(deployment.reload.status).to eq("active")
      expect(deployment.degraded_at).to be_nil
    end

    it "does NOT readopt on another chassis's success while the failing chassis is unresolved" do
      # The agent-side rule, transplanted: an error persists until THAT
      # subsystem next succeeds; another subsystem's success never clears it.
      # Chassis B replaying fine does not prove chassis A can reach the NB DB.
      stub_probe(not_measured)
      reconcile!(nb_observation: observation(applied: 0, planned: 5, last_error: "no route to host"))
      expect(deployment.reload.status).to eq("degraded")

      node_b = create(:system_node, account: account, node_template: node_template)
      instance_b = create(:system_node_instance, node: node_b, status: "running",
                                                 network_profile: "heavyweight")
      reconcile!(nb_observation: observation(applied: 5, planned: 5), via: instance_b)

      expect(deployment.reload.status).to eq("degraded")
    end

    it "clears a failing entry whose chassis instance row was deleted" do
      # Deleting the instance is a positive fact (its subject is gone), so the
      # entry is swept — but sweeping is NOT an observation, so the deployment
      # readopts only when a positive observation then finds nothing failing.
      stub_probe(not_measured)
      reconcile!(nb_observation: observation(applied: 0, planned: 5, last_error: "no route to host"))
      expect(deployment.reload.status).to eq("degraded")

      node_b = create(:system_node, account: account, node_template: node_template)
      instance_b = create(:system_node_instance, node: node_b, status: "running",
                                                 network_profile: "heavyweight")
      instance.destroy!

      reconcile!(nb_observation: observation(applied: 5, planned: 5), via: instance_b)

      expect(deployment.reload.status).to eq("active")
    end

    it "treats an EMPTY plan as not measured, never as a healthy replay" do
      deployment.update_columns(status: "degraded", degraded_at: 10.minutes.ago)
      stub_probe(not_measured)

      # plan_commands 0 is the agent's precondition-absent no-op — it executed
      # nothing, so it proves nothing. See Manager.Reconcile's forget() branch.
      reconcile!(nb_observation: observation(applied: 0, planned: 0))

      expect(deployment.reload.status).to eq("degraded")
    end

    it "leaves an active deployment alone when no observation arrived at all" do
      stub_probe(not_measured)

      reconcile!(nb_observation: nil)

      expect(deployment.reload.status).to eq("active")
    end

    it "lets the chassis observation win over a control-plane probe that disagrees" do
      # The NB DB can be reachable from ops-hub and unreachable from the
      # chassis. The chassis is the consumer, so its measurement decides —
      # otherwise the two oracles flap against each other every tick.
      stub_probe(confirmed)

      reconcile!(nb_observation: observation(applied: 0, planned: 5, last_error: "no route to host"))

      expect(deployment.reload.status).to eq("degraded")
    end

    it "a full chassis success supersedes an earlier probe failure — same subject, direct positive" do
      stub_probe(probe_failed)
      reconcile!
      expect(deployment.reload.status).to eq("degraded")

      stub_probe(not_measured)
      reconcile!(nb_observation: observation(applied: 5, planned: 5))

      expect(deployment.reload.status).to eq("active")
    end
  end

  describe "a cache hit is not a fresh measurement — the applier executed nothing" do
    # agent/internal/sdwan/ovn_nb_applier.go on CacheHit: "a consumer must not
    # read its timestamp as evidence the NB DB is reachable NOW". These pin the
    # Rails consumer to that contract.
    before { deployment.update_columns(status: "active", activated_at: 1.hour.ago) }

    it "runs the probe on a cache-hit heartbeat and degrades when the NB DB died behind the cache" do
      # Steady state: plan unchanged, so EVERY heartbeat is a cache hit. If
      # the cache hit suppressed the probe, a dead NB DB would never be
      # measured and the deployment would stay active indefinitely.
      stub_probe(probe_failed)

      reconcile!(nb_observation: observation(applied: 5, planned: 5, cache_hit: true))

      expect(deployment.reload.status).to eq("degraded")
    end

    it "does not readopt on a cache-hit replay while the probe's fresh measured negative stands" do
      # The reviewer-traced flap: a booting chassis's observation-less
      # heartbeat lets the probe measure NB down → degraded; 15s later a
      # long-lived chassis's cache-hit heartbeat must NOT delete that fresh
      # negative on the strength of a replay from before the failure.
      stub_probe(probe_failed)
      reconcile!
      expect(deployment.reload.status).to eq("degraded")

      reconcile!(nb_observation: observation(applied: 5, planned: 5, cache_hit: true))

      expect(deployment.reload.status).to eq("degraded")
      expect(deployment.nb_observed.dig("failing", described_class::PROBE_SOURCE)).to be_present
    end

    it "a cache-hit replay does not erase the probe's recorded negative once the probe can no longer measure" do
      # The probe's failing entry is the operator-visible record of the last
      # measured negative (the sensor surfaces it verbatim). If the probe
      # later CANNOT measure (endpoint became ssl:, probe broke), a cache-hit
      # re-assertion must not delete that record — it measured nothing.
      stub_probe(probe_failed)
      reconcile!
      expect(deployment.reload.status).to eq("degraded")

      stub_probe(not_measured)
      reconcile!(nb_observation: observation(applied: 5, planned: 5, cache_hit: true))

      expect(deployment.reload.status).to eq("degraded")
      expect(deployment.nb_observed.dig("failing", described_class::PROBE_SOURCE)).to be_present
    end

    it "a cache-hit replay cannot readopt even once the failing map is swept clean" do
      # Sweeping a dead chassis's entry empties the failing map without
      # measuring anything — so the only thing standing between a cache-hit
      # re-assertion and a false readopt is the fresh-measurement requirement
      # itself.
      stub_probe(not_measured)
      reconcile!(nb_observation: observation(applied: 0, planned: 5, last_error: "no route to host"))
      expect(deployment.reload.status).to eq("degraded")

      node_b = create(:system_node, account: account, node_template: node_template)
      instance_b = create(:system_node_instance, node: node_b, status: "running",
                                                 network_profile: "heavyweight")
      instance.destroy!

      reconcile!(nb_observation: observation(applied: 5, planned: 5, cache_hit: true), via: instance_b)

      expect(deployment.reload.status).to eq("degraded")
    end

    it "readopts on a cache-hit heartbeat only once the probe freshly confirms" do
      stub_probe(probe_failed)
      reconcile!
      expect(deployment.reload.status).to eq("degraded")

      stub_probe(confirmed)
      reconcile!(nb_observation: observation(applied: 5, planned: 5, cache_hit: true))

      expect(deployment.reload.status).to eq("active")
    end
  end

  describe "the probe owns degraded / readopt when no chassis observation arrived" do
    it "degrades an active deployment whose endpoint stopped answering" do
      deployment.update_columns(status: "active", activated_at: 1.hour.ago)
      stub_probe(probe_failed)

      reconcile!

      expect(deployment.reload.status).to eq("degraded")
    end

    it "readopts a probe-degraded deployment when the probe confirms again" do
      deployment.update_columns(status: "active", activated_at: 1.hour.ago)
      stub_probe(probe_failed)
      reconcile!
      expect(deployment.reload.status).to eq("degraded")

      stub_probe(confirmed)
      reconcile!

      expect(deployment.reload.status).to eq("active")
    end

    it "never degrades on an unmeasurable endpoint" do
      deployment.update_columns(status: "active", activated_at: 1.hour.ago)
      stub_probe(not_measured)

      reconcile!

      expect(deployment.reload.status).to eq("active")
    end

    it "the probe cannot readopt a chassis-caused degradation" do
      deployment.update_columns(status: "active", activated_at: 1.hour.ago)
      stub_probe(not_measured)
      reconcile!(nb_observation: observation(applied: 0, planned: 5, last_error: "no route to host"))
      expect(deployment.reload.status).to eq("degraded")

      stub_probe(confirmed)
      reconcile!

      # The probe measures reachability from the control plane; the failing
      # chassis measures the path that actually matters. Its failure stands
      # until the SAME chassis succeeds.
      expect(deployment.reload.status).to eq("degraded")
    end
  end

  describe "observation persistence" do
    it "records the last meaningful observation without touching updated_at" do
      # ovn_nb_plan_for's cache key folds deployment.updated_at, so a pure
      # observation refresh must not churn it — otherwise every heartbeat
      # recompiles the NB plan for the whole account.
      deployment.update_columns(status: "active", activated_at: 1.hour.ago)
      stub_probe(not_measured)
      frozen_updated_at = deployment.reload.updated_at

      reconcile!(nb_observation: observation(applied: 5, planned: 5, cache_hit: true))

      deployment.reload
      expect(deployment.nb_observed["last"]).to include(
        "plan_commands"    => 5,
        "applied_commands" => 5,
        "cache_hit"        => true,
        "instance_id"      => instance.id
      )
      expect(deployment.updated_at).to eq(frozen_updated_at)
    end

    it "records the failing map with the reporting chassis and error" do
      deployment.update_columns(status: "active", activated_at: 1.hour.ago)
      stub_probe(not_measured)

      reconcile!(nb_observation: observation(applied: 2, planned: 5, last_error: "boom"))

      failing = deployment.reload.nb_observed["failing"]
      expect(failing.keys).to eq([ instance.id ])
      expect(failing[instance.id]).to include("error" => "boom", "source" => "chassis_replay")
    end
  end

  describe "scoping" do
    it "does nothing for a lightweight host — it is not an OVN chassis" do
      instance.update_columns(network_profile: "lightweight")
      stub_probe(confirmed)

      reconcile!

      expect(deployment.reload.status).to eq("pending")
    end

    it "does nothing when the account has no deployment" do
      deployment.destroy!
      stub_probe(confirmed)

      expect { reconcile! }.not_to raise_error
    end

    it "never raises into the heartbeat when the probe blows up" do
      allow(Sdwan::Ovn::NbProbe).to receive(:probe_cached).and_raise(StandardError, "boom")

      expect { reconcile! }.not_to raise_error
      # The endpoints are asserted, so bootstrapping is legitimate; what must
      # NOT happen is an activation, because nothing was ever measured.
      expect(deployment.reload.status).to eq("bootstrapping")
    end
  end
end
