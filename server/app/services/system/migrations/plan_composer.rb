# frozen_string_literal: true

module System
  module Migrations
    # Walks the dependency graph from a root record, producing an
    # ordered MigrationPlan (a Migration row + its plan_steps).
    #
    # v1 scope:
    #   - Loads the root record from the local DB
    #   - Validates the kind is declared in FederationInventoryRegistry
    #   - Walks declared dependencies via AR has_many reflection where
    #     a sensible match exists
    #   - Records one MigrationPlanStep per discovered record
    #   - Dry-run mode (default) returns the composed Migration with
    #     status="planned" — no destination-side action taken yet
    #
    # Deferred to future rounds:
    #   - Polymorphic FK traversal (subject_id + subject_type)
    #   - JSONB-embedded UUID detection + remapping
    #   - dependency policy (cascade vs link_local vs skip) per-edge
    #     resolution
    #   - Conflict-policy attachment per step
    #
    # Plan reference: Decentralized Federation §F + P5.4.
    class PlanComposer
      class ComposeError < StandardError; end

      Result = Struct.new(:ok?, :error, :migration, :step_count, keyword_init: true)

      class << self
        def compose!(**args)
          new.compose!(**args)
        end
      end

      def compose!(account:, operation:, root_kind:, root_id:,
                   destination_peer: nil, initiated_by_user: nil, dry_run: true)
        return failure("operation must be 'duplicate' or 'migrate'") unless
          ::System::Migration::OPERATIONS.include?(operation.to_s)

        unless ::System::Federation::InventoryRegistry.kind_known?(root_kind)
          return failure("root_kind #{root_kind.inspect} is not in federation_inventory.yaml")
        end

        root_record = load_record(root_kind, root_id)
        return failure("root record not found: #{root_kind}:#{root_id}") unless root_record

        unless record_in_account?(root_record, account)
          return failure("root record does not belong to account #{account.id}")
        end

        migration = ::System::Migration.create!(
          account: account,
          destination_peer: destination_peer,
          operation: operation.to_s,
          root_resource_kind: root_kind.to_s,
          root_resource_id: root_id,
          status: "planned",
          dry_run: dry_run,
          initiated_by_user: initiated_by_user
        )

        steps = []
        visited = Set.new

        walk(root_record, root_kind, migration, steps, visited)

        migration.update!(
          plan_summary: {
            "total_steps" => steps.size,
            "kinds_visited" => steps.map(&:resource_kind).tally,
            "root_kind" => root_kind.to_s,
            "root_id" => root_id.to_s,
            "composed_at" => Time.current.iso8601
          }
        )
        migration.append_audit!("event" => "plan_composed", "step_count" => steps.size)

        Result.new(
          ok?: true,
          migration: migration,
          step_count: steps.size
        )
      rescue ComposeError => e
        failure(e.message)
      rescue StandardError => e
        Rails.logger.error("[Migration::PlanComposer] #{e.class}: #{e.message}")
        failure("plan composition failed: #{e.message}")
      end

      private

      def walk(record, kind, migration, steps, visited)
        return if visited.include?([ kind.to_s, record.id ])
        visited << [ kind.to_s, record.id ]

        destination_id, payload = build_destination_payload(record, kind, migration)

        step = migration.plan_steps.create!(
          step_order: steps.size,
          resource_kind: kind.to_s,
          resource_id: destination_id,
          action: "create",
          conflict_policy: default_conflict_policy_for(kind),
          payload: payload
        )
        steps << step

        kind_info = ::System::Federation::InventoryRegistry.find_kind(kind)
        return unless kind_info

        # v1: walk declared dependencies via AR reflection. For each
        # dep kind, look for a has_many on `record` whose target model
        # class matches the dep. This catches the simple case (Account
        # has_many :users, where "user" is a declared dep of "account").
        Array(kind_info.dependencies).each do |dep_kind|
          related_records = related_records_for(record, dep_kind)
          related_records.each { |r| walk(r, dep_kind, migration, steps, visited) }
        end
      end

      # Builds the destination's intended `(resource_id, payload)` for
      # one record. Operation semantics per Locked Decision #14:
      #
      #   - duplicate: generate a FRESH UUIDv7 at the destination. Source
      #     UUID is preserved in payload.metadata.duplicated_from for
      #     lineage. The new record is independent from the moment of
      #     creation — no cross-peer identity.
      #
      #   - migrate: preserve the source UUID. The record transfers
      #     ownership (source deletes after destination acks), so only
      #     one peer holds the UUID at any instant.
      def build_destination_payload(record, kind, migration)
        payload = serialize_record(record)

        case migration.operation
        when "duplicate"
          new_id = ::UUID7.generate
          payload["id"] = new_id
          existing_metadata = payload["metadata"].is_a?(Hash) ? payload["metadata"] : {}
          payload["metadata"] = existing_metadata.merge(
            "duplicated_from" => {
              "uuid" => record.id,
              "kind" => kind.to_s,
              "at" => Time.current.iso8601
            }
          )
          [ new_id, payload ]
        when "migrate"
          [ record.id, payload ]
        else
          raise ComposeError, "unknown operation #{migration.operation.inspect}"
        end
      end

      # Tries to resolve `kind` to a model class via the same conventions
      # as the federation_api/resources controller: `System::CamelCase`,
      # `Ai::CamelCase`, top-level `CamelCase`.
      def load_record(kind, id)
        model = resolve_model(kind)
        return nil unless model

        model.find_by(id: id)
      end

      def resolve_model(kind)
        try_constantize("::System::#{kind.to_s.camelize}") ||
          try_constantize("::Ai::#{kind.to_s.camelize}") ||
          try_constantize("::#{kind.to_s.camelize}")
      end

      def try_constantize(name)
        name.constantize
      rescue NameError
        nil
      end

      def record_in_account?(record, account)
        # Account itself: scope is the account row matching the caller.
        return record.id == account.id if record.is_a?(::Account)
        # Records without an account_id column are treated as global
        # (no per-tenant scoping); we permit them.
        return true unless record.respond_to?(:account_id)
        record.account_id == account.id
      end

      # v1 reflection walk: for each has_many on the record, if the
      # target model's "kind name" matches the declared dep_kind, fetch
      # the related rows. "kind name" derived as model.name.demodulize.underscore.
      def related_records_for(record, dep_kind)
        record.class.reflect_on_all_associations(:has_many).flat_map do |assoc|
          target = assoc.klass rescue nil
          next [] unless target
          model_kind = target.name.demodulize.underscore
          next [] unless model_kind == dep_kind.to_s
          record.public_send(assoc.name).to_a
        end
      rescue StandardError => e
        Rails.logger.warn("[PlanComposer] failed to reflect #{record.class} for #{dep_kind}: #{e.message}")
        []
      end

      # v1 serialization: AR's as_json, filtered to attribute columns
      # only (excludes computed fields). Future rounds add per-kind
      # serializers with explicit redaction policy.
      def serialize_record(record)
        record.attributes
      rescue StandardError
        {}
      end

      def default_conflict_policy_for(_kind)
        # v1: every step defaults to "fail" — operator must intervene
        # on any conflict. Per-kind overrides land in a follow-up.
        "fail"
      end

      def failure(message)
        Result.new(ok?: false, error: message)
      end
    end
  end
end
