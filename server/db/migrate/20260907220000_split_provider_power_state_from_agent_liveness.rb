# frozen_string_literal: true

# IMP-231f17d71dfa — provider power state and agent liveness are two different
# facts about an instance, and `status` was carrying both.
#
# The hypervisor can only tell us whether a VM is powered on. Whether an AGENT
# is alive inside it is a separate question, answered only by a heartbeat. The
# hourly cloud sync mapped the first onto mark_running!, which erased an `error`
# the fleet reaper had written from agent silence — so an instance silent for
# four weeks was re-described as running once an hour, indefinitely.
#
# Three columns, each recording one fact rather than overwriting another:
#
#   provider_power_state / provider_power_state_at
#     What the provider last reported, kept whether or not it caused a status
#     transition. Previously this observation was consumed by the transition and
#     otherwise thrown away, so "the hypervisor says it is on but we did not
#     promote it" had nowhere to live and could not be reported.
#
#   presumed_dead_at
#     When a reap judged the instance dead FROM AGENT SILENCE. This is the
#     discriminator that makes the guard exact: an agent that has heartbeated
#     since this timestamp is genuinely back, and one that has not is not. It
#     deliberately avoids naming a duration, because this subsystem has three
#     disagreeing silence thresholds (the model's 3-minute HEARTBEAT_STALE_AFTER,
#     the reaper's 30-minute PRESUMED_DEAD_SILENCE_SECONDS, and the sensor's
#     account-tunable silent_threshold_seconds) and any choice among them would
#     be both arbitrary and a new coupling.
#
# All three are nullable with no default and no backfill. NULL presumed_dead_at
# means "no reap has judged this row dead", which is the correct reading for
# every existing row including those errored for other reasons — those keep the
# IMP-42cf03360656 stranded-row self-heal, where cloud state IS the best
# evidence available. Backfilling it from the current status would assert that
# every errored row was presumed dead, which is exactly the conflation this
# migration exists to end.
class SplitProviderPowerStateFromAgentLiveness < ActiveRecord::Migration[8.0]
  def change
    change_table :system_node_instances, bulk: true do |t|
      t.string   :provider_power_state,
                 comment: "Last provider-reported power state; an observation, not a status"
      t.datetime :provider_power_state_at,
                 comment: "When provider_power_state was observed"
      t.datetime :presumed_dead_at,
                 comment: "When a reap judged this instance dead from AGENT SILENCE; cleared by a heartbeat"
    end

    # No index. presumed_dead_at is read per-row through
    # NodeInstance#agent_recovered_since_presumed_dead?, on a row already loaded
    # by primary key; nothing filters or sorts on it. A speculative partial index
    # would cost every write on the fleet's hottest table to serve no query.
  end
end
