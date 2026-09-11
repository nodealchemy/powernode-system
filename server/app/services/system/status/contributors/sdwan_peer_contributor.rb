# frozen_string_literal: true

module System
  module Status
    module Contributors
      # One component per SDWAN peer (campaign 01a08c9b increment B3).
      #
      # ── SCOPE ───────────────────────────────────────────────────────────
      # Nothing is gone. `disconnected` is the dead-ish value and is exactly
      # the row an operator needs, and the model has no terminal state at all:
      # a peer that goes away is HARD-DESTROYED by the detacher. Excluding
      # disconnected would hide the alarm.
      #
      # ── WHY Handshake IS READ SEPARATELY FROM status ────────────────────
      # `status` here is DERIVED from `last_handshake_at`, by
      # #recompute_status_from_handshake!, which only runs when something calls
      # it — and it writes with update_column, so nothing else moves either. A
      # contributor that read only `status` would report whatever the last
      # recompute concluded, however long ago that was: a self-describing
      # control auditing itself. The Handshake condition reads the timestamp
      # directly, against the model's own windows, so a stale status shows up as
      # the two disagreeing rather than as agreement.
      class SdwanPeerContributor < ::Platform::Status::Contributor
        include ::System::Status::ConditionHelpers

        KIND  = "sdwan_peer"
        MODEL = ::Sdwan::Peer

        HANDSHAKE = "Handshake"

        LIFECYCLE = {
          "active"       => { status: true,  reason: "Active" },
          "pending"      => { status: true,  reason: "Pending" },
          "degraded"     => { status: false, reason: "Degraded" },
          "disconnected" => { status: false, reason: "Disconnected",
                              severity: ::Platform::Status::Condition::SEVERITY_DOWN }
        }.freeze

        def kind = KIND

        def account_scoped? = true

        # The SDWAN reachability and drift sensors already escalate this kind
        # (system.sdwan_peer_drift, system.sdwan_hub_unreachable) and claim
        # through SignalState.claim_notification!.
        def escalates? = false

        def each_component(account)
          return if account.blank?

          # node_instance: :node, because environment_id_for walks to the node;
          # preloading only the instance cost one system_nodes query per peer
          # (B3 review F3).
          MODEL.where(account_id: account.id)
               .includes(:network, node_instance: :node)
               .find_each { |peer| yield peer }
        end

        def ref_for(record) = record.id.to_s

        # The model has no name column; operator_label composes one from the
        # instance and the network, and falls back to the id.
        def display_name_for(record)
          record.operator_label.presence || record.id.to_s
        end

        def environment_id_for(record) = record.node_instance&.node&.environment_id

        # NOT updated_at: the model's own doc records that the heartbeat writes
        # through update_columns and never bumps it, so it would be a
        # generation that stands still while the thing changes.
        def observed_generation_for(record) = record.last_handshake_at&.iso8601

        def presentation
          { "icon" => "Share2", "label" => "SDWAN peer", "group_order" => 60 }
        end

        def links_for(_record)
          [ { "label" => "SDWAN", "path" => "/app/system/sdwan" } ]
        end

        def dependencies_for(record)
          return [] if record.node_instance_id.blank?

          [ { "kind" => "node_instance", "ref" => record.node_instance_id.to_s,
              "relation" => "requires" } ]
        end

        def actions_for(_record) = []

        def conditions_for(record)
          now = Time.current
          [
            enum_condition(type: "Lifecycle", mapping: LIFECYCLE, value: record.status, now: now),
            progressing_condition(cause: record.status.to_s == "pending" ? "Handshaking" : nil, now: now),
            handshake_condition(record, now)
          ]
        end

        private

        def handshake_condition(record, now)
          last = record.last_handshake_at
          evidence = {
            "last_handshake_at" => last&.iso8601,
            "healthy_window_seconds" => MODEL::HEALTHY_HANDSHAKE_WINDOW.to_i,
            "degraded_window_seconds" => MODEL::DEGRADED_HANDSHAKE_WINDOW.to_i,
            "status" => record.status.to_s
          }

          if last.nil?
            # Never handshaked. Not a failure while the peer is still pending —
            # that is the ordinary state of a peer waiting for its agent — so
            # the fact is reported as unmeasured rather than as a fault, and
            # Progressing carries the intent.
            return CONDITION.build(type: HANDSHAKE, status: CONDITION::UNKNOWN,
                                   reason: "NeverHandshaked", evidence: evidence, now: now)
          end

          age = (now - last).to_i
          evidence = evidence.merge("age_seconds" => age)

          if age <= MODEL::HEALTHY_HANDSHAKE_WINDOW.to_i
            CONDITION.build(type: HANDSHAKE, status: true, reason: "Fresh",
                            evidence: evidence, now: now)
          elsif age <= MODEL::DEGRADED_HANDSHAKE_WINDOW.to_i
            CONDITION.build(type: HANDSHAKE, status: false, reason: "Stale",
                            message: "last handshake #{age}s ago", evidence: evidence, now: now)
          else
            CONDITION.build(type: HANDSHAKE, status: false, reason: "Lost",
                            severity: CONDITION::SEVERITY_DOWN,
                            message: "last handshake #{age}s ago", evidence: evidence, now: now)
          end
        end
      end
    end
  end
end
