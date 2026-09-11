# frozen_string_literal: true

require "rails_helper"

# B4 — the fleet's side of the remediation plane (design §5.1, §4.3, §5.2).
#
# Every registry here is process-global and the engine's to_prepare has
# already populated it by the time a spec runs, so each example that needs a
# registry in a particular shape builds that shape itself and the suite
# restores the boot state afterwards with the same registrar production uses.
RSpec.describe "System remediation plane (B4)" do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform) }
  let(:node)     { create(:system_node, account: account, node_template: template) }
  let(:instance) { create(:system_node_instance, :running, node: node) }
  let(:bindings) { System::Fleet::DecisionEngine::SIGNAL_BINDINGS }
  let(:appliers) { System::Fleet::DecisionEngine::REMEDIATION_APPLIERS }
  let(:lane)     { System::Status::FleetRemediationLane.new }

  after { System::Status::RemediationWiring.register_all! }

  def gate_agent_for(kind)
    owner = System::Fleet::DecisionEngine.owner_for(bindings.fetch(kind))
    create(:ai_agent, account: account, agent_type: "monitor", name: "Gate #{owner}", source_key: owner)
  end

  def policy!(agent, action_category, policy)
    Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                   action_category: action_category, policy: policy, is_active: true)
  end

  def component!(kind, ref, deps: [])
    create(:platform_component_status, account: account, component_kind: kind,
                                       component_ref: ref, dependencies: deps)
  end

  def signal_event!(kind, fingerprint, at: Time.current)
    System::FleetEvent.create!(account: account, kind: kind, severity: "medium",
                               payload: { "fingerprint" => fingerprint }, emitted_at: at)
  end

  describe "registration" do
    it "registers the fleet lane for every bound signal kind and for nothing else" do
      System::Status::RemediationWiring.register_all!

      ours = Platform::Remediation::Registry.lanes
               .select { |_kind, registered| registered.is_a?(System::Status::FleetRemediationLane) }
      expect(ours.keys).to match_array(bindings.keys)
      expect(Platform::Remediation::Registry.lane_for("system.no_such_bound_kind")).to be_nil
    end

    it "does not stack a second source, catalog or emitter when to_prepare runs again" do
      2.times { System::Status::RemediationWiring.register_all! }

      expect(Platform::Status::SignalSources.sources.count { |s| s.is_a?(System::Status::FleetSignalSource) }).to eq(1)
      expect(Platform::Runbook::Registry.registered_sources.count { |s| s.is_a?(System::Runbooks::Catalog) }).to eq(1)
      expect(Platform::Status::Emitters.registered?(System::Status::FleetFeedMirror::NAME)).to be true
    end

    it "answers runbook lookups from runbooks.yml only once the catalog is registered" do
      kind = bindings.keys.find { |k| System::Runbooks::Catalog.load.documented?(k) }
      expect(kind).to be_present

      Platform::Runbook::Registry.registered_sources
        .select { |s| s.is_a?(System::Runbooks::Catalog) }
        .each { |s| Platform::Runbook::Registry.unregister_source(s) }
      expect(Platform::Runbook::Registry.render(kind)[:kind]).to eq("none")

      System::Status::RemediationWiring.register_all!
      expect(Platform::Runbook::Registry.render(kind)[:kind]).to eq("doc")
    end
  end

  describe "consent: describe consumes nothing, a proceed consumes exactly one unit" do
    let(:kind) { "system.config_drift" }
    let(:mod) do
      create(:system_node_module, account: account, node_platform: platform, category: category,
                                  variety: "subscription", name: "budgeted-mod")
    end
    let(:component) { component!("node_module", mod.id) }

    before do
      expect(appliers).to have_key(kind)
      expect(bindings.fetch(kind)[:advisory]).not_to eq(true)
      policy!(gate_agent_for(kind), bindings.fetch(kind)[:action_category], "auto_approve")
      mod.update!(consent_budget_per_day: 5, consent_budget_used_count: 1,
                  consent_budget_window_start_at: Time.current)
    end

    it "reports headroom and leaves the used count where it was, however often it is asked" do
      reports = Array.new(3) { lane.describe(component, kind, account: account) }

      expect(mod.reload.consent_budget_used_count).to eq(1)
      expect(reports.last).to include(state: "auto_in_progress", can_proceed: true,
                                      consent: include(remaining: 4, budget: 5))
    end

    it "consumes one unit per proceed, through the fleet gate" do
      result = lane.proceed!(component, kind, account: account)

      expect(result[:decision]).to eq(:proceed)
      expect(mod.reload.consent_budget_used_count).to eq(2)
    end

    context "when the budget is exhausted" do
      before { mod.update!(consent_budget_used_count: 5) }

      it "describes awaiting_operator with the budget's own words, still consuming nothing" do
        report = lane.describe(component, kind, account: account)

        expect(report).to include(state: "awaiting_operator", can_proceed: false)
        expect(report[:reason]).to eq("budget_exhausted: 5/5 used in current window")
        expect(mod.reload.consent_budget_used_count).to eq(5)
      end

      it "gates a proceed to pending on the exhausted budget" do
        result = lane.proceed!(component, kind, account: account)

        expect(result).to include(decision: :pending, gate: "consent_budget_exhausted")
        expect(mod.reload.consent_budget_used_count).to eq(5)
      end
    end
  end

  describe "INV-1: the self-management fence" do
    let(:kind) { "system.instance_state_drifted" }
    let(:sibling_node) { create(:system_node, account: account, node_template: template, name: "sibling-node") }
    let(:sibling) { create(:system_node_instance, :running, node: sibling_node) }

    before do
      expect(appliers).to have_key(kind)
      policy!(gate_agent_for(kind), bindings.fetch(kind)[:action_category], "auto_approve")
    end

    context "with the self-hosting node configured" do
      before { SiteSetting.set("self_hosting_node_id", node.id) }

      it "describes the self-hosting instance as not_actuatable in the fence's own words" do
        report = lane.describe(component!("node_instance", instance.id), kind, account: account)

        expect(report).to include(state: "not_actuatable", can_proceed: false)
        expect(report[:reason]).to include("INV-1").and include(node.id)
      end

      it "does not fence an instance on any other node" do
        report = lane.describe(component!("node_instance", sibling.id), kind, account: account)

        expect(report).to include(state: "auto_in_progress", can_proceed: true)
        expect(report[:reason].to_s).not_to include("INV-1")
      end

      it "fences a component whose only link to the node is its dependency edge" do
        deps = [ { "kind" => "node_instance", "ref" => instance.id, "relation" => "requires" } ]
        report = lane.describe(component!("sdwan_peer", SecureRandom.uuid, deps: deps), kind, account: account)

        expect(report).to include(state: "not_actuatable")
        expect(report[:reason]).to include("INV-1")
      end

      it "refuses a proceed on the self-hosting instance without reaching the gate" do
        expect_any_instance_of(System::Fleet::FleetAutonomyService).not_to receive(:gate_action!)

        result = lane.proceed!(component!("node_instance", instance.id), kind, account: account)
        expect(result).to include(decision: :denied)
        expect(result[:reason]).to include("INV-1")
      end
    end

    it "is inert when no self-hosting node is configured" do
      report = lane.describe(component!("node_instance", instance.id), kind, account: account)

      expect(report).to include(state: "auto_in_progress")
    end

    it "never actuates a platform_subsystem component" do
      report = lane.describe(component!("platform_subsystem", "redis"), kind, account: account)

      expect(report).to include(state: "not_actuatable", can_proceed: false)
      expect(report[:reason]).to include("INV-1")
    end
  end

  describe "gate state mapping" do
    let(:kind) { "system.instance_state_drifted" }
    let(:agent) { gate_agent_for(kind) }
    let(:component) { component!("node_instance", instance.id) }

    it "maps require_approval to awaiting_operator" do
      policy!(agent, bindings.fetch(kind)[:action_category], "require_approval")

      expect(lane.describe(component, kind, account: account))
        .to include(state: "awaiting_operator", can_proceed: false, policy: "require_approval")
    end

    it "maps block to not_actuatable" do
      policy!(agent, bindings.fetch(kind)[:action_category], "block")

      expect(lane.describe(component, kind, account: account))
        .to include(state: "not_actuatable", can_proceed: false, policy: "block")
    end

    it "is not_actuatable when the owner has no policy row for the category at all" do
      agent

      expect(lane.describe(component, kind, account: account))
        .to include(state: "not_actuatable", can_proceed: false)
    end

    it "reports an observation-only binding as not_actuatable even when the gate would proceed" do
      observed = bindings.keys.find { |k| !appliers.key?(k) && bindings[k][:skill].nil? }
      expect(observed).to be_present
      policy!(gate_agent_for(observed), bindings.fetch(observed)[:action_category], "auto_approve")

      report = lane.describe(component, observed, account: account)
      expect(report).to include(state: "not_actuatable", can_proceed: false)
      expect(report[:reason]).to include("NoRemediationApplier")
    end
  end

  describe "FleetAutonomyService#preview_gate" do
    let(:agent) { create(:ai_agent, account: account, agent_type: "monitor", name: "Fleet Autonomy") }
    let(:service) { System::Fleet::FleetAutonomyService.new(account: account, agent: agent) }
    let(:action_category) { "system.instance_reboot" }

    %w[auto_approve notify_and_proceed require_approval block silent].each do |policy|
      it "decides #{policy} exactly as gate_action! does" do
        policy!(agent, action_category, policy)

        preview = service.preview_gate(action_category, metadata: {})
        actual = System::Fleet::FleetAutonomyService.new(account: account, agent: agent)
                   .gate_action!(action_category, metadata: {})
        expect(preview.slice(:decision, :gate)).to eq(actual.slice(:decision, :gate))
      end
    end

    it "refuses an unpermitted category exactly as gate_action! does" do
      preview = service.preview_gate("system.not_a_policy_row", metadata: {})
      actual = service.gate_action!("system.not_a_policy_row", metadata: {})

      expect(preview.slice(:decision, :reason)).to eq(actual.slice(:decision, :reason))
    end

    it "writes nothing: no approval request and no fleet event" do
      policy!(agent, action_category, "require_approval")

      expect { service.preview_gate(action_category, metadata: {}) }
        .not_to(change { [ Ai::ApprovalRequest.count, System::FleetEvent.count ] })
    end
  end

  describe System::Status::FleetSignalSource do
    let(:source) { described_class.new }
    let(:kind) { "system.instance_state_drifted" }
    let(:fingerprint) { "instance_state_drifted:#{instance.id}" }
    let(:component) { component!("node_instance", instance.id) }

    it "reports a standing signal whose fingerprint names the component" do
      signal_event!(kind, fingerprint)

      facts = source.call(component)
      expect(facts).to contain_exactly(include(signal_kind: kind, fingerprint: fingerprint, stuck: false))
    end

    it "ignores a signal older than the episode window" do
      window = System::Fleet::SignalState.setting("episode_reset_seconds")
      signal_event!(kind, fingerprint, at: (window + 60).seconds.ago)

      expect(source.call(component)).to be_empty
    end

    it "ignores a signal about another component and an unbound kind" do
      signal_event!(kind, "instance_state_drifted:#{SecureRandom.uuid}")
      signal_event!("platform.component_down", fingerprint)

      expect(source.call(component)).to be_empty
    end

    it "carries the last settled outcome and the stuck streak" do
      signal_event!(kind, fingerprint)
      outcome = lambda do |status, at|
        System::Fleet::RemediationOutcome.create!(account: account, signal_kind: kind, fingerprint: fingerprint,
                                                  status: status, acted_at: at, settle_until: at,
                                                  validated_at: at)
      end

      outcome.call("effective", 2.hours.ago)
      expect(source.call(component).sole).to include(last_outcome: "succeeded", stuck: false)

      threshold = System::Fleet::DecisionEngine::STUCK_STREAK_THRESHOLD
      threshold.times { |i| outcome.call("ineffective", (threshold - i).minutes.ago) }
      expect(source.call(component).sole).to include(last_outcome: "failed", stuck: true)
    end

    it "carries the pending approval the fleet gate minted for the fingerprint" do
      # The fleet gate mints approvals on an Ai::ApprovalChain, which a private
      # extension defines; without it there is no approval to carry.
      skip "requires Ai::ApprovalChain (defined by a private extension)" unless defined?(::Ai::ApprovalChain)

      create(:ai_approval_chain, account: account, trigger_type: "autonomy_action", name: "Fleet Autonomy Actions")
      agent = create(:ai_agent, account: account, agent_type: "monitor", name: "Fleet Autonomy")
      policy!(agent, "system.instance_reboot", "require_approval")
      gated = System::Fleet::FleetAutonomyService.new(account: account, agent: agent)
                .gate_action!("system.instance_reboot", metadata: { "signal_fingerprint" => fingerprint })
      signal_event!(kind, fingerprint)

      expect(gated[:decision]).to eq(:pending)
      expect(source.call(component).sole[:approval_request_id]).to eq(gated[:decision_record].id)
    end
  end

  describe "RemediationRefresh once the fleet source is registered" do
    let(:kind) { "system.instance_state_drifted" }
    let(:sibling_node) { create(:system_node, account: account, node_template: template, name: "sibling-node") }
    let(:sibling) { create(:system_node_instance, :running, node: sibling_node) }

    it "skips with no source, then derives real states from the fleet's own signals" do
      policy!(gate_agent_for(kind), bindings.fetch(kind)[:action_category], "auto_approve")
      SiteSetting.set("self_hosting_node_id", node.id)
      own = component!("node_instance", instance.id)
      other = component!("node_instance", sibling.id)
      signal_event!(kind, "instance_state_drifted:#{instance.id}")
      signal_event!(kind, "instance_state_drifted:#{sibling.id}")

      Platform::Status::SignalSources.sources
        .select { |s| s.is_a?(System::Status::FleetSignalSource) }
        .each { |s| Platform::Status::SignalSources.unregister(s) }
      blind = Platform::Status::RemediationRefresh.run!(account)
      expect(blind).to include(skipped: true, reason: "NoSignalSources")
      expect(own.reload.remediation).to be_blank

      System::Status::RemediationWiring.register_all!
      seen = Platform::Status::RemediationRefresh.run!(account)
      expect(seen).to include(skipped: false)
      expect(own.reload.remediation).to include("state" => "not_actuatable", "signal_kind" => kind)
      expect(other.reload.remediation).to include("state" => "auto_in_progress", "signal_kind" => kind)
    end
  end

  describe System::Status::FleetFeedMirror do
    def status_event!(kind, from, to)
      Platform::StatusEvent.create!(account: account, component_kind: "node_instance", component_ref: instance.id,
                                    kind: kind, from_verdict: from, to_verdict: to, occurred_at: Time.current)
    end

    def transition(from, to, account_id: account.id)
      { account_id: account_id, component_kind: "node_instance", component_ref: instance.id,
        from: from, to: to, at: Time.current }
    end

    before { System::Status::RemediationWiring.register_all! }

    it "mirrors each status event into the fleet feed, severity from the verdict it moved to" do
      down = status_event!("platform.component_down", "ok", "down")
      Platform::Status::Emitters.notify(transition: transition("ok", "down"), events: [ down ])

      mirrored = System::FleetEvent.where(account: account, kind: "platform.component_down").sole
      expect(mirrored).to have_attributes(severity: "high", node_instance_id: instance.id,
                                          source: described_class::SOURCE)
      expect(mirrored.payload).to include("status_event_id" => down.id, "from" => "ok", "to" => "down")

      degraded = status_event!("platform.component_status_changed", "ok", "degraded")
      Platform::Status::Emitters.notify(transition: transition("ok", "degraded"), events: [ degraded ])
      expect(System::FleetEvent.where(account: account, kind: "platform.component_status_changed").sole.severity)
        .to eq("medium")
    end

    it "mirrors nothing for a shared component, which has no fleet account" do
      event = status_event!("platform.component_down", "ok", "down")

      expect do
        Platform::Status::Emitters.notify(transition: transition("ok", "down", account_id: nil), events: [ event ])
      end.not_to change(System::FleetEvent, :count)
    end

    it "mirrors nothing once the emitter is unregistered" do
      Platform::Status::Emitters.unregister(described_class::NAME)
      event = status_event!("platform.component_down", "ok", "down")

      expect do
        Platform::Status::Emitters.notify(transition: transition("ok", "down"), events: [ event ])
      end.not_to change(System::FleetEvent, :count)
    end
  end
end
