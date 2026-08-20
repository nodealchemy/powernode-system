# frozen_string_literal: true

module System
  module Executors
    # Executor wired into AutonomyGate when System::Task#before_create gates
    # the dispatch. After approval (or auto-approval) lands, this executor
    # actually inserts the task and lets the existing
    # `System::Task#enqueue_execution` after_commit hook push the job.
    #
    # Why an executor instead of inline create? It keeps every gated
    # operation symmetrical — the audit row, the status flow, and the
    # approval chain all behave identically across SDWAN, Runtime, and
    # Task domains.
    class ExecuteTask < Base
      protected

      def perform
        attrs = task_attrs.slice(
          :command, :description, :scheduled_at, :exclusive,
          :operable_type, :operable_id, :idempotency_key, :options,
          :initiated_by_id
        )

        operable = resolve_operable(attrs.delete(:operable_type), attrs.delete(:operable_id))

        task = ::System::Task.new(attrs)
        task.account = account
        task.operable = operable if operable
        task.initiated_by_id ||= deferred_operation&.requested_by_id
        task.save!

        {
          task_id: task.id,
          status: task.status,
          command: task.command
        }
      end

      # The operable arrives as a caller-supplied type/id pair that the gate
      # stored verbatim and replays at approval time with no re-validation, and
      # System::Task's polymorphic belongs_to is `optional: true` with no
      # ownership check — so mass-assigning the pair let a caller attach another
      # account's record to a task executing under their own account.
      #
      # Two independent refusals: the allowlist decides WHAT may be an operable
      # (System::Task validates it too, but constantizing an arbitrary
      # caller-supplied string to reach that validation is itself the thing to
      # avoid), and resolve_scoped decides WHOSE row it may be. The resolved
      # record — not the raw pair — is what gets attached, so the check and the
      # assignment cannot drift apart.
      def resolve_operable(type, id)
        return nil if type.blank? || id.blank?

        unless ::System::Task::OPERABLE_TYPES.include?(type)
          raise ::System::Task::BadOperableType,
                "#{type} is not a valid task operable"
        end

        resolve_scoped(type.constantize, id)
      rescue ActiveRecord::RecordNotFound
        # An id that exists elsewhere and an id that exists nowhere must be
        # indistinguishable. resolve_scoped's `find` raises RecordNotFound for
        # the second and CrossAccountError for the first, and Ai::AutonomyGate
        # renders both messages to the caller — so the PAIR is an existence
        # oracle even though neither message names an owner.
        #
        # Converted here rather than in resolve_scoped: that seam is shared by
        # every executor and its RecordNotFound contract is pinned
        # (base_tenancy_spec.rb:110), so changing it there would be a
        # behavioural change for callers this task has no business touching.
        # Re-raised unchanged when there is no anchor to name, matching
        # resolve_scoped's unscoped passthrough.
        raise unless account

        raise ::Ai::DeferredOperation::CrossAccountError,
              "#{type} #{id} is not in account #{account.id}"
      end

      # IMP-a449bc347e94: summarize/impact read the same normalized shape
      # perform inserts. They previously read params[:command] and
      # params[:operable_type]/[:operable_id] at the TOP level while both gate
      # call sites nest under :task_attributes — so every deferred task's card
      # read "Execute system task: " with impact " on system", naming neither
      # the command nor the target the approver is deciding about.
      # THE LABEL BOTH SURFACES OF ONE APPROVAL SHOW (IMP-1dd3ed2b5353).
      #
      # The approvals API serves `description` — frozen by the gate site at
      # request time — beside `preview[:impact]`, recomputed from this executor.
      # Once #impact learned to name the operable, every gate site's raw
      # "cmd on Type#uuid" became a SECOND, disagreeing label for the same
      # decision on the same card. Same defect IMP-ee57d0fbe859 fixed for
      # DeletePeer, and the same fix: one source, consulted by both.
      #
      # Deliberately the PREVIEW rather than a parallel formatter. A rival
      # label path would agree today and drift the next time #impact changes,
      # which is exactly how this bug arrived. Callers therefore get the
      # literal string the card will render.
      #
      # No deferred_operation exists yet at a gate site, which is the
      # anchor-less pre-gate case #name_disclosable? already handles: it falls
      # back to the initiator both HTTP surfaces force into task_attrs, and
      # #operable_display degrades to the bare Type#id pair wherever the name
      # cannot be resolved or disclosed. So the fallback below is only reached
      # if the preview itself raises — a label must never fail a control-plane
      # request — and it is the same pair #operable_display degrades to, not a
      # second opinion about how to name things.
      def self.gate_description(task_attributes)
        attrs = task_attributes.respond_to?(:to_unsafe_h) ? task_attributes.to_unsafe_h : task_attributes.to_h
        attrs = attrs.symbolize_keys
        # Braces are load-bearing: `preview(task_attributes: attrs)` is parsed as
        # KEYWORDS (preview takes a keyword `deferred_operation:`), leaving the
        # positional `params` unbound — an ArgumentError this method's own
        # rescue would have swallowed straight into the fallback.
        preview({ task_attributes: attrs })[:impact].presence || bare_pair(attrs)
      rescue StandardError => e
        Rails.logger.warn("[ExecuteTask] gate_description preview failed: #{e.class}: #{e.message}")
        bare_pair(attrs || {})
      end

      def self.bare_pair(attrs)
        target = [ attrs[:operable_type], attrs[:operable_id] ].compact_blank
        target.empty? ? attrs[:command].to_s : "#{attrs[:command]} on #{target.join('#')}"
      end
      private_class_method :bare_pair

      def summarize
        "Execute system task: #{task_attrs[:command]}"
      end

      def impact
        attrs = task_attrs
        "#{attrs[:command]} on #{operable_display(attrs[:operable_type], attrs[:operable_id])}"
      end

      private

      # The row attributes, wherever the caller put them. Both gate call sites
      # nest under :task_attributes (tasks_controller#create and
      # NodeInstanceGating's gate_or_execute / gate_ip_action); :attributes and
      # the bare top level cover direct callers. One ladder shared by perform
      # and the card pair keeps the shapes from drifting apart again.
      def task_attrs
        raw = params[:task_attributes] || params[:attributes] || params
        raw = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw.to_h
        raw.symbolize_keys
      end

      # Names the operable for the approval card — the approver decides "stop
      # WHICH node", so the card leads with the record's name and degrades to
      # the caller's own Type#id pair when nothing better resolves.
      #
      # Resolution is DELEGATED to resolve_operable — the same allowlist,
      # scoping, and oracle-collapsing perform uses — so what the card will
      # name and what the executor will touch cannot drift apart (the exact
      # drift resolve_operable's own comment exists to prevent). The card
      # degrades where perform refuses: every refusal renders as the caller's
      # own bare pair, because a preview must render, not raise.
      def operable_display(type, id)
        return "system" if type.blank? || id.blank?

        fallback = "#{type}##{id}"
        record = resolve_operable(type, id)
        return fallback unless name_disclosable?(record)

        name = record.respond_to?(:name) ? record.name : nil
        name.present? ? "#{type} #{name}" : fallback
      rescue ::System::Task::BadOperableType, ::Ai::DeferredOperation::CrossAccountError,
             ActiveRecord::RecordNotFound
        fallback
      end

      # Whether the resolved record's name may appear on the card. With the
      # operation present, resolve_operable already anchored the record to the
      # operation's account and this passes — which as of IMP-4a5094b22df0 is
      # BOTH the execute path and every card composed through
      # Ai::DeferredOperation#preview. The remaining anchor-less caller is a
      # PRE-GATE preview (`preview(params)` with no operation), where
      # resolve_scoped passes ANY existing row through unscoped — and there the
      # only trusted anchor is the initiator both HTTP gate surfaces force
      # into task_attrs after their permit lists (tasks_controller#create
      # merges current_user.id over the permitted keys; NodeInstanceGating
      # writes it directly). Without this check the card would hand a
      # caller-named foreign UUID's name back at REQUEST time, before any
      # approval: a cross-account disclosure and an existence oracle in one.
      # Records that carry no account anchor at all are not tenant-owned and
      # disclose freely, mirroring resolve_scoped's own passthrough.
      def name_disclosable?(record)
        return true if account.present?

        owner_id = record.account_id if record.respond_to?(:account_id)
        owner_id ||= record.account&.id if record.respond_to?(:account)
        return true if owner_id.nil?

        owner_id == ::User.find_by(id: task_attrs[:initiated_by_id])&.account_id
      end
    end
  end
end
