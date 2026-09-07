# frozen_string_literal: true

require "rails_helper"

# IMP-231f17d71dfa — the truth table for the one decision three reconciliation
# paths share.
#
# The call sites disagree on mechanism: Api::V1::System::WorkerApi and
# Api::V1::Internal::System both fire AASM events, while
# System::CloudSyncService#sync_region_instances — the path the hourly
# SystemCloudSyncJob actually takes — writes `status:` with a bare update! that
# consults no may_X? guard. Only one of those three has request-spec coverage at
# all (there is no spec/requests/api/v1/internal/system directory), so this
# pins the predicate itself rather than relying on each caller's own tests to
# notice a change underneath them.
RSpec.describe System::NodeInstance, "provider power state vs agent liveness" do
  let(:account) { create(:account) }
  let(:node)    { create(:system_node, account: account) }

  def instance_with(status:, last_heartbeat_at:, presumed_dead_at:)
    inst = create(:system_node_instance, account: account, node: node, status: "running")
    inst.update_columns(status: status,
                        last_heartbeat_at: last_heartbeat_at,
                        presumed_dead_at: presumed_dead_at)
    inst.reload
  end

  describe "#agent_recovered_since_presumed_dead?" do
    it "is true when no reap has judged the instance dead" do
      inst = instance_with(status: "error", last_heartbeat_at: 3.days.ago, presumed_dead_at: nil)
      expect(inst.agent_recovered_since_presumed_dead?).to be true
    end

    it "is false when the agent has not spoken since the verdict" do
      inst = instance_with(status: "error", last_heartbeat_at: 3.days.ago, presumed_dead_at: 1.hour.ago)
      expect(inst.agent_recovered_since_presumed_dead?).to be false
    end

    # REACHABILITY NOTE. In steady state this reduces to presumed_dead_at.nil?,
    # because #record_heartbeat! is the only writer of last_heartbeat_at and it
    # clears the stamp. The `>` comparison is reached only when a heartbeat whose
    # attrs were built from a pre-reap in-memory row lands AFTER the reaper's
    # stamp, leaving a row with both a stamp and a newer heartbeat. So this
    # example pins that RACE, not the ordinary recovery path — the ordinary path
    # is StatusController#heartbeat promoting directly, covered by the
    # decision_engine example that asserts the stamp is retired. Stated because a
    # reader would otherwise take this for recovery coverage it does not provide.
    it "is true when the agent spoke after the verdict (the late-heartbeat race)" do
      inst = instance_with(status: "error", last_heartbeat_at: 1.minute.ago, presumed_dead_at: 10.minutes.ago)
      expect(inst.agent_recovered_since_presumed_dead?).to be true
    end

    # A row that never enrolled cannot have "recovered". Returning true here
    # would let provider state promote an instance no agent has ever run on,
    # which is the F1 seed-contamination shape from IMP 019fe4c4-b373.
    it "is false when there is a verdict and the instance has never reported" do
      inst = instance_with(status: "error", last_heartbeat_at: nil, presumed_dead_at: 1.hour.ago)
      expect(inst.agent_recovered_since_presumed_dead?).to be false
    end

    # Boundary: equal timestamps mean the heartbeat did not arrive AFTER the
    # verdict, so the verdict stands. Stated because a `>=` here would silently
    # promote on the reap's own tick.
    it "is false when the heartbeat is exactly the verdict instant" do
      at = 1.hour.ago
      inst = instance_with(status: "error", last_heartbeat_at: at, presumed_dead_at: at)
      expect(inst.agent_recovered_since_presumed_dead?).to be false
    end
  end

  describe "#provider_state_may_promote?" do
    # Only ONE cell of this table is contested. Every other answer must be true,
    # or the guard starts making decisions that belong to other code — refusing
    # a stop or a termination, for instance, would leave the platform unable to
    # follow a VM the operator powered off.
    it "refuses only running-from-error-while-silent" do
      silent = instance_with(status: "error", last_heartbeat_at: 3.days.ago, presumed_dead_at: 1.hour.ago)
      expect(silent.provider_state_may_promote?("running")).to be false
    end

    it "allows stopped, terminated and error reports on that same row" do
      silent = instance_with(status: "error", last_heartbeat_at: 3.days.ago, presumed_dead_at: 1.hour.ago)

      expect(silent.provider_state_may_promote?("stopped")).to be true
      expect(silent.provider_state_may_promote?("terminated")).to be true
      expect(silent.provider_state_may_promote?("error")).to be true
    end

    it "allows running for a row that is not in error, whatever its heartbeat" do
      starting = instance_with(status: "starting", last_heartbeat_at: nil, presumed_dead_at: nil)
      expect(starting.provider_state_may_promote?("running")).to be true
    end

    it "allows running once the agent has come back" do
      recovered = instance_with(status: "error", last_heartbeat_at: 1.minute.ago,
                                presumed_dead_at: 10.minutes.ago)
      expect(recovered.provider_state_may_promote?("running")).to be true
    end

    # The callers pass provider vocabulary straight through, so the predicate
    # normalises with to_s: a SYMBOL :running is the same report as the string
    # and is refused, while nil and any status that is not a promotion are
    # uncontested. Pinning the symbol case because an == comparison against the
    # bare string would silently let a symbol through.
    it "normalises the report rather than trusting its type" do
      silent = instance_with(status: "error", last_heartbeat_at: 3.days.ago, presumed_dead_at: 1.hour.ago)

      expect(silent.provider_state_may_promote?(nil)).to be true
      expect(silent.provider_state_may_promote?("pending")).to be true
      expect(silent.provider_state_may_promote?(:running)).to be false
    end
  end

  # Review finding: a verdict is scoped to ONE error episode, and clearing it
  # only in #record_heartbeat! leaves it set on every other exit from :error.
  # A leftover then refuses a LATER, unrelated error — the exact case the nil
  # semantics promise to leave alone.
  describe "retiring the verdict when the instance leaves :error" do
    it "clears the stamp when an operator starts a reaped instance" do
      inst = instance_with(status: "error", last_heartbeat_at: 3.days.ago,
                           presumed_dead_at: 1.hour.ago)

      inst.start!

      expect(inst.reload.presumed_dead_at).to be_nil
    end

    # The whole sequence, because each step looks harmless alone: the refusal at
    # the end is what a stale verdict causes, and it must not happen.
    it "lets a later provider-reported error be promoted out of again" do
      inst = instance_with(status: "error", last_heartbeat_at: 3.days.ago,
                           presumed_dead_at: 1.hour.ago)
      inst.start!                                   # operator intervenes
      inst.update_columns(status: "error")          # a LATER, provider-reported error

      expect(inst.reload.provider_state_may_promote?("running")).to be true
    end

    # A bare update! is the shape System::CloudSyncService#sync_region_instances
    # uses, so a callback that only fired on AASM events would miss the writer
    # that matters most. before_save catches both.
    it "clears the stamp on a bare status write, not only on an AASM event" do
      inst = instance_with(status: "error", last_heartbeat_at: 3.days.ago,
                           presumed_dead_at: 1.hour.ago)

      inst.update!(status: "stopped")

      expect(inst.reload.presumed_dead_at).to be_nil
    end

    it "leaves the stamp alone while the instance is still in error" do
      inst = instance_with(status: "error", last_heartbeat_at: 3.days.ago,
                           presumed_dead_at: 1.hour.ago)

      inst.update!(public_ip_address: "203.0.113.7")

      expect(inst.reload.presumed_dead_at).to be_present
    end
  end

  describe "#record_provider_power_state!" do
    it "records the observation without touching updated_at" do
      inst = instance_with(status: "error", last_heartbeat_at: 3.days.ago, presumed_dead_at: 1.hour.ago)

      expect { inst.record_provider_power_state!("running") }
        .not_to change { inst.reload.updated_at }

      expect(inst.reload.provider_power_state).to eq("running")
      expect(inst.provider_power_state_at).to be_present
    end

    it "ignores a blank report rather than recording an empty observation" do
      inst = instance_with(status: "running", last_heartbeat_at: 1.minute.ago, presumed_dead_at: nil)
      inst.record_provider_power_state!(nil)
      expect(inst.reload.provider_power_state).to be_nil
    end
  end
end
