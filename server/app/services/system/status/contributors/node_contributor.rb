# frozen_string_literal: true

module System
  module Status
    module Contributors
      # One component per Node (campaign 01a08c9b increment B2).
      #
      # ── SCOPE: NOTHING IS "GONE" FOR THIS KIND, AND THAT IS THE FACT ────
      # System::Node has no status column, no enum, no AASM and no soft-delete.
      # Its only lifecycle attribute is the boolean `enabled`, and a destroyed
      # node takes its instances with it (`dependent: :destroy`) — so the row
      # existing IS the record being live, and every row is enumerated. A
      # disabled node is not gone: it is operator intent, and it reports `held`.
      #
      # ── THERE IS NO NODE HEALTH COLUMN, SO HEALTH IS DERIVED ────────────
      # The one observable liveness fact reachable from a node is the state of
      # the provider connections behind its instances
      # (instance -> provider_region -> provider -> provider_connections). That
      # traversal is eager-loaded in one pass rather than walked per node; it is
      # the most expensive thing this contributor does and it is bounded by the
      # account's instance count.
      class NodeContributor < ::Platform::Status::Contributor
        include ::System::Status::ConditionHelpers

        KIND = "node"

        MODEL      = ::System::Node
        CONNECTION = ::System::ProviderConnection

        # Every value of ProviderConnection::STATUSES. `pending` is a real
        # observed state — the connection exists and has not come up — so it is
        # a false condition, not an unknown one. Blindness and a connection that
        # has not connected are different facts.
        CONNECTION_STATES = {
          "connected" => { status: true,  reason: "Connected" },
          "pending"   => { status: false, reason: "ConnectionPending" },
          "error"     => { status: false, reason: "ConnectionErrored" }
        }.freeze

        PROVIDER_REACHABLE = "ProviderReachable"

        def kind = KIND

        def account_scoped? = true

        # Fleet kinds keep their lane's escalation (design §5.4). This one is
        # already escalated by the fleet tick's instance-level lanes, which claims through
        # SignalState.claim_notification! — so leaving core's A7 escalation on
        # would page twice for one outage, claimed in two places, neither aware
        # of the other. The claim is fleet-side and keyed by fleet fingerprint;
        # core cannot see it. Owner: a node's trouble reaches an operator through its instances' own signals.
        def escalates? = false

        def each_component(account)
          return if account.blank?

          MODEL.where(account_id: account.id)
               .includes(node_instances: { provider_region: { provider: :provider_connections } })
               .find_each { |node| yield node }
        end

        def ref_for(record) = record.id.to_s

        def display_name_for(record) = record.name.presence || record.id.to_s

        def environment_id_for(record) = record.environment_id

        # No version or lock column on system_nodes; updated_at is all there is.
        def observed_generation_for(record) = record.updated_at&.iso8601

        def presentation
          { "icon" => "Server", "label" => "Node", "group_order" => 20 }
        end

        # No per-node detail route: the node detail is a modal on the nodes list
        # that holds its selection in React state and never changes the URL.
        def links_for(_record)
          [ { "label" => "Nodes", "path" => "/app/system/compute/nodes" } ]
        end

        # A node depends on nothing this plane models. Its instances depend on
        # IT (they declare `hosts`), and the rollup reverse-walks those edges to
        # get a node's impact — so declaring the reverse here would double the
        # graph and make every edge appear twice with opposite meaning.
        def dependencies_for(_record) = []

        # No node member route mutates a node in a way an operator would drive
        # from a status drawer: create/update/destroy are CRUD, and
        # apply_template is a template operation gated on system.modules.update
        # rather than a node action. Nothing is offered rather than something
        # mislabelled.
        def actions_for(_record) = []

        def conditions_for(record)
          now = Time.current
          [
            held_condition(cause: record.enabled? ? nil : "Disabled",
                           message: record.enabled? ? nil : "the node is disabled",
                           now: now),
            provider_reachable_condition(record, now)
          ].compact
        end

        private

        # Omitted entirely for a disabled node: its provider link is not a
        # question anyone is asking, and answering `unknown` would rank a
        # deliberately disabled node ABOVE a held one on the ladder and turn
        # operator intent amber.
        def provider_reachable_condition(record, now)
          return nil unless record.enabled?

          statuses = connection_statuses(record)

          if statuses.empty?
            return CONDITION.build(
              type: PROVIDER_REACHABLE, status: CONDITION::UNKNOWN, reason: "NoProviderConnection",
              message: "this node has no instance whose provider carries a connection, so its " \
                       "provider link is unobserved",
              evidence: { "instance_count" => record.node_instances.size }, now: now
            )
          end

          worst = worst_connection_status(statuses)
          condition = enum_condition(
            type: PROVIDER_REACHABLE, mapping: CONNECTION_STATES, value: worst,
            evidence: { "connection_statuses" => statuses.tally }, now: now
          )

          # `down` has to be asked for. Every connection failed means the node
          # has no provider path at all; one of several is a degradation.
          return condition unless worst == "error" && statuses.uniq == [ "error" ]

          condition.merge("severity" => CONDITION::SEVERITY_DOWN)
        end

        def connection_statuses(record)
          record.node_instances.filter_map { |instance| instance.provider_region&.provider }
                .uniq
                .flat_map { |provider| provider.provider_connections.select(&:enabled?) }
                .map { |connection| connection.status.to_s }
        end

        # Worst-first over the states we map, then anything unmapped — which
        # must win, so an unrecognised connection state cannot be masked by a
        # `connected` sibling and read as healthy.
        def worst_connection_status(statuses)
          unmapped = statuses.reject { |status| CONNECTION_STATES.key?(status) }
          return unmapped.first if unmapped.any?

          %w[error pending connected].find { |status| statuses.include?(status) }
        end
      end
    end
  end
end
