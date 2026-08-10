# frozen_string_literal: true

require "rails_helper"

# Campaign 019f6084 inc-M — System::FulfillmentRequestSweepService: the tick that
# (a) advances open requests forward via the orchestrator (resuming ones parked
# at the build barrier / approved out-of-band) and (b) reaps task-scoped leases at
# expiry. Mirrors spec/services/system/ci_runner_lease_sweep_service coverage
# shape (advance + reap in one run).
RSpec.describe System::FulfillmentRequestSweepService do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }
  let!(:region)  { create(:system_provider_region, account: account, enabled: true) }
  let!(:itype)   { create(:system_provider_instance_type, account: account) }
  let!(:base_os) do
    create(:system_node_module, account: account, node_platform: platform, category: category,
           name: System::Ai::Skills::FulfillCapabilityRequestExecutor::DEFAULT_BASE_OS_MODULE_NAME)
  end

  def running_instance
    template = create(:system_node_template, account: account, node_platform: platform)
    node = create(:system_node, account: account, node_template: template)
    create(:system_node_instance, :running, node: node)
  end

  def composed(**attrs)
    ::System::FulfillmentRequest.create_composed!(
      account: account, request: "give me memcached",
      plan: { "execution" => { "count" => 1, "base_os_module_id" => base_os.id,
                               "base_os_module_name" => base_os.name, "reused_modules" => [],
                               "gaps" => [], "provider_region_id" => nil,
                               "provider_instance_type_id" => nil, "platform_id" => platform.id,
                               "template_name" => "fulfill-x-#{SecureRandom.hex(2)}" } },
      cost_estimate: {}, reused_modules: [], lease_ttl_seconds: 3600, **attrs
    )
  end

  describe "#advance_open! (drives open records via the orchestrator)" do
    it "advances an approved (no-gap, all-reused) request toward completion" do
      # An all-reused request (no gaps) has no build barrier — it authors a
      # template + provisions. With no region/type in the frozen plan, provision
      # parks and the run reaches `ready` with a park note (env-limited, honest).
      fr = composed
      fr.approve!

      summary = described_class.run!(account: account)

      expect(summary[:advanced]).to be >= 1
      fr.reload
      expect(fr).to be_ready
      expect(fr.parked.map { |p| p["step"] }).to include("provision")
    end

    it "does NOT touch composed (unapproved) requests" do
      fr = composed # stays composed
      described_class.run!(account: account)
      expect(fr.reload).to be_composed
    end
  end

  describe "#reap_expired! (task-scoped lease reaper)" do
    it "terminates a ready run's instances and expires it once past expires_at" do
      inst = running_instance
      fr = composed
      %i[approve! start_materializing! mark_templated! start_provisioning! start_smoking! mark_ready!]
        .each { |e| fr.public_send(e) }
      fr.record_instances!([ inst.id ])
      fr.update!(expires_at: 1.minute.ago)

      allow(::System::ProvisioningService).to receive(:terminate_instance)
        .and_return(instance_double("Result", success?: true))

      summary = described_class.run!(account: account)

      expect(::System::ProvisioningService).to have_received(:terminate_instance).with(instance: inst)
      expect(summary[:requests_expired]).to eq(1)
      expect(fr.reload).to be_expired
    end

    it "terminates a stray task_scoped instance past its own lease_expires_at (backstop)" do
      inst = running_instance
      inst.update!(lifecycle_class: "task_scoped", lease_expires_at: 1.minute.ago)
      allow(::System::ProvisioningService).to receive(:terminate_instance)
        .and_return(instance_double("Result", success?: true))

      described_class.run!(account: account)

      expect(::System::ProvisioningService).to have_received(:terminate_instance).with(instance: inst)
    end

    it "leaves a task_scoped instance whose lease has NOT elapsed alone" do
      inst = running_instance
      inst.update!(lifecycle_class: "task_scoped", lease_expires_at: 1.hour.from_now)
      allow(::System::ProvisioningService).to receive(:terminate_instance)

      described_class.run!(account: account)

      expect(::System::ProvisioningService).not_to have_received(:terminate_instance)
    end
  end

  # An authoring artifact left by a process KILL between NodeTemplate.create and
  # record_template! (no exception ran, so none of the orchestrator's
  # rescue-cleanup did either). FulfillmentAdvanceOrchestrator#
  # reclaim_abandoned_template! reclaims one for a request that can still resume
  # onto it — but that path is NAME-COLLISION triggered and fires only from the
  # owning request's own next author_template!. When the owner is TERMINAL or
  # gone, nothing re-enters that path and the artifact is unreachable forever:
  # the orchestrator says so itself ("Nothing reaps unreferenced orphans yet;
  # that is a separate sweep, not this method's job"). This is that sweep.
  describe "#reap_orphan_templates! (authoring artifacts no request can reclaim)" do
    def stamped_template(request_id, created_at: 1.hour.ago, name: nil)
      tmpl = create(:system_node_template, account: account, node_platform: platform,
                    name: name || "fulfill-orphan-#{SecureRandom.hex(3)}")
      tmpl.update_columns(config: { "fulfillment_request_id" => request_id }, created_at: created_at)
      tmpl
    end

    def terminal_request(state: "failed", templated_at: 3.hours.ago)
      fr = composed
      fr.update_columns(state: state, templated_at: templated_at)
      fr
    end

    def exists?(tmpl)
      ::System::NodeTemplate.where(id: tmpl.id).exists?
    end

    it "reaps an orphan whose owning request failed terminally" do
      orphan = stamped_template(terminal_request.id)

      described_class.run!(account: account)

      expect(exists?(orphan)).to be(false)
    end

    it "reaps an orphan whose owning request no longer exists" do
      fr = terminal_request
      orphan = stamped_template(fr.id)
      fr.delete

      described_class.run!(account: account)

      expect(exists?(orphan)).to be(false)
    end

    it "counts what it reaped so a tick that cleans up says so" do
      stamped_template(terminal_request.id)

      expect(described_class.run!(account: account)[:orphan_templates_reaped]).to eq(1)
    end

    # ---- guards: everything below must SURVIVE the sweep ----

    # The self-heal's case, not the reaper's. An advanceable request may still
    # resume onto its own artifact, and reaping it would race that resume.
    it "leaves an orphan whose owning request is still advanceable" do
      fr = composed
      fr.update_columns(state: "templated", templated_at: 3.hours.ago)
      orphan = stamped_template(fr.id)

      # Hold the request advanceable across the tick. Unstubbed, advance_open!
      # runs FIRST and carries it to `ready` — at which point the stamped
      # artifact really is unreclaimable and reaping it is correct. That is the
      # advancer's effect, not the reaper's decision, and this example is about
      # the reaper's decision.
      allow(::System::FulfillmentAdvanceOrchestrator).to receive(:advance!)
        .and_return(instance_double("Result", already_advancing: true))

      described_class.run!(account: account)

      expect(exists?(orphan)).to be(true)
    end

    # A run predating the stamp, or any operator template. Unstamped means
    # unidentifiable, and unidentifiable must never mean reapable.
    it "leaves a template carrying no fulfillment stamp at all" do
      plain = create(:system_node_template, account: account, node_platform: platform)
      # Aged PAST the grace period on purpose, so the stamp clause is the only
      # thing protecting it. Left at `created_at = now` this example passes
      # even with the stamp requirement removed entirely — it was the grace
      # period doing the work, and the clause it claims to pin went untested.
      plain.update_columns(created_at: 1.hour.ago)

      described_class.run!(account: account)

      expect(exists?(plain)).to be(true)
    end

    # Same anti-forgery clause reclaim_abandoned_template! uses: an operator's
    # system_update_template REPLACES config wholesale, so a stamp that predates
    # the request's own templated_at did not come from that request's authoring.
    it "leaves a stamped template that predates its request's templated_at" do
      fr = terminal_request(templated_at: 1.hour.ago)
      forged = stamped_template(fr.id, created_at: 5.hours.ago)

      described_class.run!(account: account)

      expect(exists?(forged)).to be(true)
    end

    it "leaves a stamped template that has nodes attached" do
      orphan = stamped_template(terminal_request.id)
      create(:system_node, account: account, node_template: orphan)

      summary = described_class.run!(account: account)

      expect(exists?(orphan)).to be(true)
      # Asserted on the COUNTERS too, not just survival: `has_many :nodes,
      # dependent: :restrict_with_error` would refuse the destroy anyway, so a
      # reaper that skipped this check would still leave the row — but it would
      # do so by raising into the rescue. Survival alone cannot tell "declined"
      # from "tried and was stopped by the database".
      expect(summary[:orphan_templates_reaped]).to eq(0)
      expect(summary[:errored]).to eq(0)
    end

    it "leaves a template a request recorded as its live artifact" do
      fr = terminal_request
      recorded = stamped_template(fr.id)
      fr.update_columns(template_id: recorded.id)

      described_class.run!(account: account)

      expect(exists?(recorded)).to be(true)
    end

    # A template authored seconds ago by a run whose owner went terminal
    # mid-flight in another process: the reaper does not hold the orchestrator's
    # per-request advisory lock, so age is the only thing separating a dead
    # artifact from one still being assembled.
    it "leaves a stamped orphan younger than the grace period" do
      fresh = stamped_template(terminal_request.id, created_at: 1.minute.ago)

      described_class.run!(account: account)

      expect(exists?(fresh)).to be(true)
    end

    it "never reaps another account's orphan" do
      other = create(:account)
      fr = terminal_request
      foreign = create(:system_node_template, account: other,
                       node_platform: create(:system_node_platform, account: other))
      foreign.update_columns(config: { "fulfillment_request_id" => fr.id }, created_at: 1.hour.ago)

      described_class.run!(account: account)

      expect(exists?(foreign)).to be(true)
    end
  end

  # IMP-2401f2183c63 — the sweep is the platform's most consequential 60-second
  # actuator (instance termination, template destroy!, live template apply) and
  # ran with ZERO gates. Both gates stand down the WHOLE sweep, bookkeeping
  # expiry included: deferring pure expiry by a tick is free, while a split
  # gated/ungated sweep is exactly the complexity that grows a bypass. Matches
  # the fenced reconcilers' uniform posture (FleetAutonomyService halts its
  # approval-expiry sweep under the kill-switch too).
  describe "gating" do
    let(:service) { described_class.new(account: account) }

    it "no-ops entirely while the kill-switch is engaged" do
      account.suspend_ai!

      expect(service).not_to receive(:advance_open!)
      expect(service).not_to receive(:reap_expired!)

      result = service.run!

      expect(result[:ok]).to be false
      expect(result[:halted]).to be true
    end

    it "stands down entirely on a non-active control plane" do
      allow(::System::Autonomy::ControlPlaneRole).to receive(:active?).and_return(false)

      expect(service).not_to receive(:advance_open!)
      expect(service).not_to receive(:reap_expired!)

      result = service.run!

      expect(result[:ok]).to be false
      expect(result[:standby]).to be true
    end

    it "reports halted, not standby, when both gates would fire" do
      account.suspend_ai!
      allow(::System::Autonomy::ControlPlaneRole).to receive(:active?).and_return(false)

      result = service.run!

      expect(result[:halted]).to be true
      expect(result[:standby]).to be_nil
    end

    it "sweeps normally when unhalted on an active (or unarmed) plane" do
      expect(service).to receive(:advance_open!)
      expect(service).to receive(:reap_expired!)
      expect(service).to receive(:reap_orphan_templates!)

      result = service.run!

      expect(result).to have_key(:advanced)
    end
  end
end
