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
    #   ExecutorClass.preview(params, deferred_operation:) → { summary:, impact: }
    #
    # `preview` takes its context on the same keyword as `execute`
    # (IMP-4a5094b22df0), so an approval card can be anchored to the account the
    # gate opened the operation in. Two differences from `execute`, both
    # deliberate:
    #
    #   * the keyword is OPTIONAL. The pre-gate path previews before any
    #     DeferredOperation exists, so `preview(params)` alone stays a supported
    #     call — it simply has no anchor, and #scoped_label_record names nothing
    #     rather than naming a row whose owner nobody has established.
    #   * what arrives is NOT the operation. Ai::DeferredOperation#preview
    #     passes an Ai::DeferredOperation::PreviewContext, which answers
    #     `account` and nothing else. So `#account`, `#resolve_scoped` and
    #     `#scoped_label_record` work unchanged, and `#requesting_user` returns
    #     nil through its existing respond_to? guard — while the operation's
    #     `params`, `result` and `take_revealed_result!` are absent from the
    #     context entirely, and `#initiator` raises because it dereferences a
    #     `requested_by`/`ai_agent` the context does not carry. An executor
    #     reaching for execution state while composing a card therefore raises,
    #     and Ai::DeferredOperation#preview's rescue degrades it to a generic
    #     card instead of rendering that state to an approver. Do not "fix"
    #     such a raise by threading the operation; the absence is the guard.
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

        def preview(params, deferred_operation: nil)
          new(params, deferred_operation: deferred_operation).preview_payload
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

      def account
        deferred_operation&.account
      end

      # Account-anchored lookup for a row an approval CARD is about to NAME.
      # The label seam: before IMP-4a5094b22df0 each summarize hand-rolled its
      # own find, and they disagreed — some read the row unscoped, some scoped
      # it by an account_id the CALLER had put in params[:attributes] (the one
      # hash `attrs` strips the tenancy keys out of before any write).
      #
      # NOT yet universal: IMP-4a5094b22df0 migrated the six executors named in
      # its file list, and roughly eleven siblings still resolve their label row
      # unscoped (delete_peer, delete_network, update_firewall_rule,
      # update_virtual_ip, delete_virtual_ip, failover_virtual_ip,
      # delete_access_grant, revoke_user_device, instance_pool/delete_pool,
      # runtime/decommission_k3s_cluster, disk_image/promote_publication).
      # They are unsafe on the same terms and are queued as a follow-on sweep
      # (offer 01a0046b-6488) — a new executor should route here rather than
      # copy one of them.
      #
      # Deliberately NOT resolve_scoped, in both directions:
      #
      #   * it never raises. resolve_scoped guards a WRITE and refusing loudly
      #     is right there; this guards a sentence shown to a human, and a card
      #     that 500s is worse than a card naming a bare id.
      #   * it fails CLOSED with no anchor, where resolve_scoped passes through.
      #     resolve_scoped's pass-through is safe because the caller authorised
      #     the write upstream; there is no equivalent upstream authorisation
      #     for a DISCLOSURE, and an unanchored disclosure is exactly the leak
      #     this exists to stop. So no account ⇒ no name, and the caller
      #     degrades to the id it was given.
      #
      # Callers pass the id they would have looked up anyway and treat nil as
      # "render the id instead" — never as "not found", which it also covers.
      def scoped_label_record(model, id)
        return nil if id.blank?

        anchor = account
        return nil if anchor.nil?
        # A model with no account of its own cannot be anchored, and asking
        # PostgreSQL for the column would raise inside a card render.
        return nil unless model.respond_to?(:column_names) && model.column_names.include?("account_id")

        model.find_by(id: id, account_id: anchor.id)
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
      # Base.preview when invoked PRE-GATE (its `deferred_operation:` keyword
      # defaults to nil; a preview reached through Ai::DeferredOperation#preview
      # instead carries an Ai::DeferredOperation::PreviewContext, which does
      # answer `account`), Ai::Tools::SystemFleetTool, and
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
