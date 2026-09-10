# frozen_string_literal: true

module System
  module Status
    module Contributors
      # One component per live InstancePool (campaign 01a08c9b increment B2).
      #
      # ── SCOPE: WHAT "GONE" MEANS FOR THIS KIND ──────────────────────────
      # `archived`, and nothing else. It is the terminal value of
      # InstancePool::STATUSES; `paused` and `draining` are operator intent and
      # stay on the screen reporting `held`, because a pool someone is winding
      # down is exactly the thing an operator wants to keep watching.
      #
      # ── CAPACITY IS COUNTED THE WAY THE POOL COUNTS IT ──────────────────
      # Membership is keyed on `pool_state`, never on the instance's own
      # `status` — the model's own counters do this and the database enforces
      # that the two pool columns are set together. This contributor calls those
      # counters rather than re-deriving them, so a change to what "ready" means
      # cannot make the pool's own summary and the status plane disagree.
      class InstancePoolContributor < ::Platform::Status::Contributor
        include ::System::Status::ConditionHelpers

        KIND = "instance_pool"

        MODEL = ::System::InstancePool

        GONE_STATUSES = %w[archived].freeze

        # Every value of MODEL::STATUSES. `paused` and `draining` report true
        # here and carry their intent on the Held condition instead — the
        # lifecycle fact is "this pool is not broken", which is true of all
        # three live states.
        LIFECYCLE = {
          "active"   => { status: true,  reason: "Active" },
          "paused"   => { status: true,  reason: "Paused" },
          "draining" => { status: true,  reason: "Draining" },
          # Never enumerated; mapped so a scope defect cannot read as healthy.
          "archived" => { status: false, reason: "Archived",
                          severity: ::Platform::Status::Condition::SEVERITY_DOWN }
        }.freeze

        CAPACITY = "Capacity"
        MEMBERS  = "MembersHealthy"

        def kind = KIND

        def account_scoped? = true

        def each_component(account)
          return if account.blank?

          MODEL.where(account_id: account.id)
               .where.not(status: GONE_STATUSES)
               .includes(:node_instances)
               .find_each { |pool| yield pool }
        end

        def ref_for(record) = record.id.to_s

        def display_name_for(record) = record.name.presence || record.id.to_s

        def environment_id_for(record) = record.environment_id

        # No version or lock column on system_instance_pools; updated_at only.
        def observed_generation_for(record) = record.updated_at&.iso8601

        def presentation
          { "icon" => "Droplet", "label" => "Instance pool", "group_order" => 30 }
        end

        # The pools list is a real route; the pool detail is a modal on it that
        # keeps its selection in React state, so there is no per-pool URL.
        def links_for(_record)
          [ { "label" => "Instance pools", "path" => "/app/system/instance-pools" } ]
        end

        # A pool's members declare `backs` toward it; the rollup reverse-walks
        # those to get the pool's impact. Declaring the reverse here would state
        # the same edge twice with opposite meaning.
        def dependencies_for(_record) = []

        # The three real member routes. All three pass the controller's
        # authorize_write!, which accepts `system.instances.create` OR
        # `system.instances.control`; the narrower of the two is declared, so
        # every operator who sees a button can use it and nobody who can use one
        # is denied a button they would have been allowed.
        def actions_for(record)
          base = "/api/v1/system/instance_pools/#{record.id}"
          [
            {
              "key" => "replenish", "label" => "Replenish", "method" => "POST",
              "path" => "#{base}/replenish", "permission" => "system.instances.control",
              "destructive" => false,
              "confirm" => { "prompt" => "Replenish #{display_name_for(record)} to its target size?",
                             "requires_reason" => false }
            },
            {
              "key" => "drain", "label" => "Drain", "method" => "POST",
              "path" => "#{base}/drain", "permission" => "system.instances.control",
              "destructive" => true,
              "confirm" => { "prompt" => "Drain #{display_name_for(record)}? Its members are wound down.",
                             "requires_reason" => true }
            },
            {
              "key" => "recycle_stale", "label" => "Recycle stale members", "method" => "POST",
              "path" => "#{base}/recycle_stale", "permission" => "system.instances.control",
              "destructive" => true,
              "confirm" => { "prompt" => "Recycle stale members of #{display_name_for(record)}?",
                             "requires_reason" => true }
            }
          ]
        end

        def conditions_for(record)
          now = Time.current
          [
            enum_condition(type: "Lifecycle", mapping: LIFECYCLE, value: record.status, now: now),
            held_condition(cause: held_cause(record), now: now),
            progressing_condition(cause: record.warming_count.positive? ? "Replenishing" : nil, now: now),
            capacity_condition(record, now),
            members_condition(record, now)
          ].compact
        end

        private

        def held_cause(record)
          case record.status.to_s
          when "paused"   then "Paused"
          when "draining" then "Draining"
          end
        end

        # Three-way, and warming counts toward the target: a pool actively
        # filling to target is not short, it is filling. A pool that is short
        # even counting what is warming IS short, and one with no ready member
        # at all against a non-zero target cannot serve a claim — that is a
        # total loss of the pool's function, so it is the one that asks for
        # `down`.
        #
        # A target of zero is a legitimately empty pool, not an exhausted one.
        def capacity_condition(record, now)
          ready   = record.ready_count
          warming = record.warming_count
          target  = record.target_size.to_i
          evidence = {
            "ready_count" => ready, "warming_count" => warming,
            "claimed_count" => record.claimed_count, "target_size" => target,
            "min_size" => record.min_size, "max_size" => record.max_size
          }

          if ready.zero? && target.positive?
            return CONDITION.build(
              type: CAPACITY, status: false, reason: "Exhausted",
              severity: CONDITION::SEVERITY_DOWN,
              message: "no ready member against a target of #{target}; a claim cannot be served",
              evidence: evidence, now: now
            )
          end

          if (ready + warming) < target
            return CONDITION.build(
              type: CAPACITY, status: false, reason: "BelowTarget",
              message: "#{ready} ready + #{warming} warming against a target of #{target}",
              evidence: evidence, now: now
            )
          end

          CONDITION.build(
            type: CAPACITY, status: true,
            reason: ready >= target ? "AtTarget" : "FillingToTarget",
            message: "#{ready} ready + #{warming} warming against a target of #{target}",
            evidence: evidence, now: now
          )
        end

        # Only a question where there are members. A pool with none has no
        # member health to report, and claiming `ok` there would be the
        # constant-that-cannot-fail this plane exists to delete.
        #
        # Gated on TOTAL membership, not on active_member_count: that counter
        # spans warming/ready/claimed and deliberately excludes `errored`, so a
        # pool whose every member has errored has an active count of zero — and
        # gating on it would drop this condition in exactly the case it exists
        # to report.
        def members_condition(record, now)
          errored = record.errored_count
          return nil if (record.active_member_count + errored).zero?

          CONDITION.build(
            type: MEMBERS, status: errored.zero?,
            reason: errored.zero? ? "MembersHealthy" : "MembersErrored",
            message: errored.zero? ? nil : "#{errored} member(s) in pool_state errored",
            evidence: { "errored_count" => errored,
                        "active_member_count" => record.active_member_count },
            now: now
          )
        end
      end
    end
  end
end
