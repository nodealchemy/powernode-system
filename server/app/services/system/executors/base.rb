# frozen_string_literal: true

module System
  module Executors
    # Convenience base for executor classes — concrete subclasses override
    # `perform` (and optionally `summarize`/`impact`) instead of the bare
    # `execute`/`preview` contract. Keeps the dispatcher signature identical
    # while providing helpers (lookup helpers, error translation, etc.) that
    # most concrete executors share.
    #
    # The contract Ai::AutonomyGate expects:
    #
    #   ExecutorClass.execute(params, deferred_operation:) → { success:, data: }
    #   ExecutorClass.preview(params)                       → { summary:, impact: }
    #
    # Subclasses normally only override `perform` and `summarize`.
    class Base
      # Keys a caller must never mass-assign through params[:attributes].
      # account_id is mass-assignable on every model these executors write, the
      # gate stores the attributes verbatim, and Ai::DeferredOperation replays
      # them at approval time with no re-validation — so leaving them in `attrs`
      # let a request move a record into an account of the caller's choosing.
      TENANCY_ATTRIBUTE_KEYS = %i[account account_id].freeze

      class << self
        def execute(params, deferred_operation:)
          new(params, deferred_operation: deferred_operation).call
        end

        def preview(params)
          new(params, deferred_operation: nil).preview_payload
        end
      end

      attr_reader :params, :deferred_operation

      def initialize(params, deferred_operation:)
        @params = (params || {}).with_indifferent_access
        @deferred_operation = deferred_operation
      end

      def call
        result = perform
        { success: true, data: result }
      rescue StandardError => e
        Rails.logger.error("[#{self.class.name}] failed: #{e.class}: #{e.message}")
        raise
      end

      def preview_payload
        {
          summary: summarize,
          impact: impact
        }
      end

      protected

      # Subclasses override these
      def perform
        raise NotImplementedError, "#{self.class.name} must implement #perform"
      end

      def summarize
        self.class.name.demodulize.underscore.humanize
      end

      def impact
        nil
      end

      # Create/update attribute payload coerced to a symbol-keyed Hash. The
      # SDWAN CRUD executors all receive their attributes under
      # params[:attributes]; this centralizes the `to_h.symbolize_keys`
      # coercion. Nil-safe (nil.to_h is {}), and returns a fresh Hash each call
      # so callers can merge/mutate a local copy without touching params.
      #
      # TENANCY_ATTRIBUTE_KEYS are dropped here rather than per-executor: an
      # executor that forgets is the whole vulnerability, and every executor
      # that legitimately sets an account already does so from a trusted anchor
      # (`account`, or the account of a record resolved through resolve_scoped).
      def attrs
        params[:attributes].to_h.symbolize_keys.except(*TENANCY_ATTRIBUTE_KEYS)
      end

      # The account the CALLER named, for label scoping only — never for
      # assignment. Preview/summarize run through Base.preview, which hardcodes
      # `deferred_operation: nil`, so `account` is nil there by construction and
      # the request's own attributes are the only thing an approval card can
      # scope its lookups by.
      def requested_account_id
        params[:attributes].to_h.symbolize_keys[:account_id]
      end

      def account
        deferred_operation&.account
      end

      # Account-anchored lookup for the records an executor resolves FOR ITSELF
      # during perform. Ai::DeferredOperation asserts the source_type/source_id
      # pair the gate recorded; this covers the other anchor — ids taken from
      # caller-supplied params, which the gate stored verbatim and replays with
      # no re-validation (a create has no source pair at all, since no row
      # exists yet).
      #
      # Executors are intentionally unscoped as a class — ownership is enforced
      # upstream by the controllers' set_* guards — and a blanket
      # `where(account_id:)` would break the callers that reach an executor with
      # no account at all, turning every find into `where(account_id: nil)`:
      # fail-open dressed as fail-closed. Those callers pass a literal nil —
      # Base.preview (which hardcodes it), Ai::Tools::SystemFleetTool, and
      # System::Ai::Skills::ServiceDiscoveryComposerExecutor. The OTHER
      # duck-typed shape does carry one and is anchored like any operation:
      # MultiTenantIsolationExecutor's `Struct.new(:account)` context and the
      # k3s federation smoke test's `Struct.new(:account, :requested_by)`.
      #
      # So this passes through unscoped when there is no account to anchor on,
      # and refuses only when there IS one and the record answers with a
      # different owner.
      def resolve_scoped(model, id)
        record = model.find(id)
        anchor = account
        return record if anchor.nil?

        owner_id = record.account_id if record.respond_to?(:account_id)
        owner_id ||= record.account&.id if record.respond_to?(:account)
        return record if owner_id.nil? || owner_id == anchor.id

        # Owner logged, not raised — Ai::AutonomyGate renders a raised message
        # back to the caller, and naming the owner answers a cross-tenant probe.
        Rails.logger.warn(
          "[#{self.class.name}] refused #{model.name} #{id}: belongs to account #{owner_id}, not #{anchor.id}"
        )
        raise ::Ai::DeferredOperation::CrossAccountError,
              "#{model.name} #{id} is not in account #{anchor.id}"
      end

      # Guard for update executors whose attributes can carry a NEW parent id.
      # `attrs` drops account/account_id (the tenancy MOVE), but a
      # caller-supplied parent foreign key is equally tenancy-bearing — the
      # RE-PARENT (IMP-bf996c7abcb4 ruling): the SDWAN models' own validations
      # are RELATIVE to the row's parent (holders/hub/target/name-uniqueness
      # compare against the row's network, never against this operation's
      # account), so a payload naming a foreign parent satisfies every model
      # validation while account_id stays the caller's — and the per-network
      # compilers then file the row into the victim's overlay.
      #
      # Resolving the named parent through resolve_scoped is the whole guard:
      # in-account re-parents still work, a foreign parent raises
      # CrossAccountError before the write, and when no new parent is named
      # the row's existing parent is already covered by the executor's own
      # resolve_scoped. Hoisted here (IMP-0e44cf2fc80b) because the copy had
      # reached four executors byte-identical — and an update executor that
      # forgets this call is a silent tenancy hole; see the per-resource
      # compile-path rationale at each call site.
      def anchor_reparent!(attribute, model)
        parent_id = attrs[attribute]
        return if parent_id.blank?

        resolve_scoped(model, parent_id)
      end

      def initiator
        deferred_operation&.requested_by || deferred_operation&.ai_agent
      end

      # The requesting USER, nil-safe across the duck-typed
      # deferred_operation shapes enumerated on resolve_scoped — two of
      # which (Base.preview's literal nil and MultiTenantIsolationExecutor's
      # Struct.new(:account) context) have no requested_by at all. NOT
      # #initiator: that falls back to ai_agent, which is wrong wherever a
      # User id is recorded (e.g. VipAssignment#triggered_by_user_id).
      def requesting_user
        deferred_operation.respond_to?(:requested_by) ? deferred_operation.requested_by : nil
      end
    end
  end
end
