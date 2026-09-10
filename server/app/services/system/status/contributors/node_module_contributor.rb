# frozen_string_literal: true

module System
  module Status
    module Contributors
      # One component per NodeModule (campaign 01a08c9b increment B3).
      #
      # ── THIS KIND HAS NO STATUS ENUM, AND SAYING SO IS THE POINT ────────
      # system_node_modules carries no status, no state and no health column.
      # Its one enum, VARIETIES, is a DISCRIMINATOR — config / instance /
      # subscription say what a module IS, never how it is doing — so it is
      # carried as evidence rather than dressed up as a condition. A condition
      # built from it would be true for every row by construction, which is the
      # constant-that-cannot-fail the composite probe was written to delete.
      #
      # The two facts that CAN come back wrong are whether an operator disabled
      # it, and whether it has ever been built into a version the fleet can
      # serve.
      #
      # ── SCOPE ───────────────────────────────────────────────────────────
      # Nothing is gone: no soft delete, no archived state, hard destroy only.
      # A disabled module is operator intent and reports `held`.
      class NodeModuleContributor < ::Platform::Status::Contributor
        include ::System::Status::ConditionHelpers

        KIND  = "node_module"
        MODEL = ::System::NodeModule

        PUBLISHED = "Published"

        def kind = KIND

        def account_scoped? = true

        # Fleet kinds keep their lane's escalation (design §5.4): module drift
        # and promotion are escalated by the fleet tick's own lanes
        # (system.module_drift, system.module_promotion_stalled), which claim
        # through SignalState.claim_notification!.
        def escalates? = false

        def each_component(account)
          return if account.blank?

          MODEL.where(account_id: account.id).find_each { |mod| yield mod }
        end

        def ref_for(record) = record.id.to_s

        def display_name_for(record) = record.name.presence || record.id.to_s

        def observed_generation_for(record) = record.current_version_number&.to_s

        def presentation
          { "icon" => "Package", "label" => "Node module", "group_order" => 50 }
        end

        def links_for(_record)
          [ { "label" => "Modules", "path" => "/app/system/catalog/modules" } ]
        end

        # A module's node edges run through an assignment join table and are
        # many-to-many; the instance-scoped varieties carry an optional
        # node_instance_id. Only the direct, single-valued edge is declared —
        # the join is a set, and a status edge per assignment would be the
        # dependents graph rather than this row's own dependencies.
        def dependencies_for(record)
          return [] if record.node_instance_id.blank?

          [ { "kind" => "node_instance", "ref" => record.node_instance_id.to_s,
              "relation" => "requires" } ]
        end

        def actions_for(_record) = []

        def conditions_for(record)
          now = Time.current
          [
            held_condition(cause: record.enabled? ? nil : "Disabled", now: now),
            published_condition(record, now)
          ]
        end

        private

        # A module with no current version has never produced anything a node
        # can materialise. It is not broken — nothing failed — but it is not
        # serviceable either, and an operator who assigned it to a template is
        # waiting on a build that may never have been dispatched.
        def published_condition(record, now)
          published = record.current_version_id.present?

          CONDITION.build(
            type: PUBLISHED,
            status: published,
            reason: published ? "Published" : "NeverBuilt",
            message: published ? nil : "no current version — nothing for a node to materialise",
            evidence: {
              "variety" => record.variety.to_s,
              "current_version_number" => record.current_version_number,
              "enabled" => record.enabled?
            },
            now: now
          )
        end
      end
    end
  end
end
