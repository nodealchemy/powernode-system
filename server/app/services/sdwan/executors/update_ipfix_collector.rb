# frozen_string_literal: true

module Sdwan
  module Executors
    # Executor for `sdwan.ipfix_collector_update` (IMP-6bbe5c673c38).
    #
    # The state toggle is the ONLY non-destructive way to stop a collector
    # exporting. Until this landed it existed on REST only, so an agent
    # holding Ai::Tools::SdwanTool could reach exactly one verb for the
    # "stop this collector" intent: delete — which cascades the collector's
    # flow_samples (`dependent: :destroy` on the model, `on_delete: :cascade`
    # on the FK) and takes the correlation history the fleet sensors read
    # with it. Disable keeps the row and its samples and merely stops the
    # compiler stamping the `ipfix:` block onto the account's OVS bridges.
    #
    # Category tier follows the rule IMP-97c7b4123d8f stated for this whole
    # family — creates and state transitions notify, deletes require
    # approval — which is the tier the structurally identical
    # `sdwan.host_bridge_update` (ActivateHostBridge) already carries.
    class UpdateIpfixCollector < ::System::Executors::Base
      ACTION_CATEGORY = "sdwan.ipfix_collector_update"

      protected

      def perform
        collector = resolve_scoped(::Sdwan::IpfixCollector, params[:collector_id])
        target = params[:state].to_s

        # Re-checked here rather than trusted from the arm: an approval can
        # sit parked for a long time, and the executor — not its caller — is
        # what actually writes.
        unless ::Sdwan::IpfixCollector::STATES.include?(target)
          raise ArgumentError, "state must be 'active' or 'disabled'"
        end

        # AASM runs with whiny_transitions: false, so a refused transition
        # returns false rather than raising. Both events accept either state
        # as a source today; the guard is here so a future narrowing of the
        # state machine surfaces as a refusal instead of a silent no-op that
        # still reports success.
        transitioned = target == "active" ? collector.enable! : collector.disable!
        raise ArgumentError, "cannot move IPFIX collector from #{collector.state} to #{target}" unless transitioned

        { collector_id: collector.id, state: collector.reload.state }
      end

      def summarize
        label = scoped_label_record(::Sdwan::IpfixCollector, params[:collector_id])&.name || params[:collector_id]
        "Set IPFIX collector #{label} to #{params[:state]}"
      end

      def impact
        if params[:state].to_s == "disabled"
          "Stops flow export from this collector; the row and its recorded flow samples are kept"
        else
          "Makes the collector eligible to be stamped onto the account's OVS bridges again"
        end
      end
    end
  end
end
