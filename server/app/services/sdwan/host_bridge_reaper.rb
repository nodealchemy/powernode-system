# frozen_string_literal: true

module Sdwan
  # Sdwan::HostBridgeReaper — sweeps draining Sdwan::HostBridge rows that
  # have outlived their grace window and marks them removed, releasing the
  # short_id back to the per-host pool.
  #
  # WHY THIS EXISTS (IMP-53a5c597ec8c). Releasing a host bridge without
  # `force` transitions it to `draining`, and the allocator's contract says
  # the row is preserved "until in-flight taps finish". Nothing implemented
  # the second half. The state machine (Sdwan::HostBridge) has no
  # draining->active edge and no automatic draining->removed edge; the
  # `compilable` scope INCLUDES draining, so Sdwan::TopologyCompiler kept
  # emitting the bridge and the on-node BridgeApplier kept it up; and the
  # agent has no report path that would retire it (the node API's sdwan
  # controller only READS host_bridges). A non-forced release therefore
  # marked the row and left the bridge fully operational forever, while
  # Sdwan::HostBridgeResolver went on handing it to new VMs and the short_id
  # was never reclaimed.
  #
  # That made `draining` a one-way door, which is why a plain DELETE on the
  # operator surface could not be defaulted to it safely. This closes the
  # door: drain now means "still serving, briefly, then gone", which is what
  # every caller's comment already claimed it meant.
  #
  # Mirrors System::Identity::ReaperService — same shape, same grace window,
  # same worker-invoked entry point — because that is the pattern this
  # platform already runs in production for drained ServiceUser/ServiceGroup
  # rows. Sdwan::VrfAllocator carries the identical gap and still says "a
  # future fleet-autonomy reaper will sweep rows older than 24h"; it is NOT
  # swept here, because VRF assignments have their own dependents and
  # deserve their own guard rather than being folded into a bridge sweep.
  class HostBridgeReaper
    # Why 24 hours: long enough that an in-flight VM provision or live
    # migration holding a tap on this bridge finishes before the bridge is
    # torn off the host; short enough that a released short_id does not sit
    # unusable for a meaningful fraction of a host's 9,999-id range. Matches
    # System::Identity::ReaperService::GRACE_WINDOW and the window
    # Sdwan::VrfAllocator's comments assume.
    GRACE_WINDOW = 24.hours

    Result = Struct.new(:ok?, :reaped_bridges, :ran_at, keyword_init: true)

    def self.run!
      new.run!
    end

    def run!
      Result.new(ok?: true, reaped_bridges: reap_bridges, ran_at: Time.current)
    end

    private

    # Only rows whose drain window has demonstrably elapsed. `draining_at` is
    # stamped by the start_drain transition, so a row with a NULL
    # draining_at (hand-crafted, or drained before that column was
    # populated) is SKIPPED rather than swept on an assumed age — the
    # comparison in SQL already excludes NULL, and that is the conservative
    # direction: a bridge whose age we cannot establish keeps serving.
    def reap_bridges
      count = 0
      ::Sdwan::HostBridge.draining
                         .where(draining_at: ...GRACE_WINDOW.ago)
                         .find_each do |bridge|
        count += 1 if bridge.mark_removed!
      end
      count
    end
  end
end
