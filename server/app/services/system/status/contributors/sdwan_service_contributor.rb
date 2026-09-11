# frozen_string_literal: true

module System
  module Status
    module Contributors
      # One component per published SDWAN service (campaign 01a08c9b B3).
      #
      # ── TWO ENUMS, TWO CONDITIONS, AND THAT IS DELIBERATE ───────────────
      # `status` is what an operator set (active / disabled) and `health_state`
      # is what the flow correlator observed (unknown / serving / silent /
      # unobservable). They fail separately and mean different things: a
      # disabled service is not silent, and a silent one is not disabled.
      # Collapsing them would make the verdict underivable from the evidence.
      #
      # `unobservable` in particular is not a failure. It is the model's way of
      # saying a service can never be correlated — and reporting that as
      # degraded would alarm forever on something nobody can fix.
      #
      # ── SCOPE ───────────────────────────────────────────────────────────
      # Nothing is gone: `disabled` is the only off value and it is operator
      # intent, so it stays on the screen reporting `held`.
      class SdwanServiceContributor < ::Platform::Status::Contributor
        include ::System::Status::ConditionHelpers

        KIND  = "sdwan_service"
        MODEL = ::Sdwan::Service

        LIFECYCLE = {
          "active"   => { status: true, reason: "Active" },
          # Intent, carried on Held. The lifecycle fact is "not broken", which
          # is true of a service someone switched off.
          "disabled" => { status: true, reason: "Disabled" }
        }.freeze

        HEALTH = {
          "serving"      => { status: true, reason: "Serving" },
          "silent"       => { status: false, reason: "Silent",
                              message: "no correlated flow inside the observation window" },
          "unknown"      => { status: ::Platform::Status::Condition::UNKNOWN,
                              reason: "NotObserved",
                              message: "no flow correlation has run for this service yet" },
          # NOT a failure: the model uses this for a service that CANNOT be
          # correlated at all. Alarming on it would alarm forever.
          "unobservable" => { status: ::Platform::Status::Condition::UNKNOWN,
                              reason: "Unobservable",
                              message: "this service cannot be correlated to a flow" }
        }.freeze

        def kind = KIND

        def account_scoped? = true

        # SdwanServiceHealthSensor already escalates this kind
        # (system.sdwan_service_silent) and claims through
        # SignalState.claim_notification!.
        def escalates? = false

        def each_component(account)
          return if account.blank?

          MODEL.where(account_id: account.id).find_each { |service| yield service }
        end

        def ref_for(record) = record.id.to_s

        def display_name_for(record)
          record.name.presence || record.slug.presence || record.id.to_s
        end

        def observed_generation_for(record) = record.updated_at&.iso8601

        def presentation
          { "icon" => "Workflow", "label" => "SDWAN service", "group_order" => 70 }
        end

        def links_for(_record)
          [ { "label" => "Service delivery", "path" => "/app/system/service-delivery" } ]
        end

        # The certificate a locally-exposed service terminates on is a real,
        # single-valued edge. There is deliberately no node edge: the model
        # carries none — its backend is a VIP or a free-text host — and
        # inventing one from backend_host would be a guess behind the root-cause
        # ranking.
        def dependencies_for(record)
          return [] if record.local_certificate_id.blank?

          [ { "kind" => "acme_certificate", "ref" => record.local_certificate_id.to_s,
              "relation" => "requires" } ]
        end

        def actions_for(_record) = []

        def conditions_for(record)
          now = Time.current
          evidence = {
            "slug" => record.slug.to_s,
            "local_enabled" => record.local_enabled,
            "public_enabled" => record.public_enabled,
            "last_observed_flow_at" => record.last_observed_flow_at&.iso8601
          }

          conditions = [
            enum_condition(type: "Lifecycle", mapping: LIFECYCLE, value: record.status, now: now),
            held_condition(cause: record.status.to_s == "disabled" ? "Disabled" : nil, now: now)
          ]
          # Health is asked only of an ACTIVE service (B3 review F2).
          # SdwanServiceHealthSensor resets health_state to `unknown` on every
          # non-active service each tick, so for a disabled one the column is a
          # value the sensor erased, not an observation, and its UNKNOWN would
          # outrank Held and read not_measured instead of held.
          if record.status.to_s == "active"
            conditions << enum_condition(type: "Health", mapping: HEALTH, value: record.health_state,
                                         evidence: evidence, now: now)
          end
          conditions
        end
      end
    end
  end
end
