# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Composition skill — register an IPFIX collector for an account.
      # Composition shape:
      #
      #   Sdwan::IpfixCollector.find_or_create_by(name)
      #     → returns metadata + is_winning_collector flag
      #
      # Idempotent on `name` within the executing account: if a collector
      # with the same name already exists, the executor returns it as-is
      # without mutating host/port/sampling_rate. Mirrors the OVN compose
      # skill's deployment-level idempotency.
      #
      # Why `is_winning_collector`: the topology compiler selects the
      # account's *oldest active* IpfixCollector when stamping the OVS
      # ipfix block on each heavyweight host's bridge payload. A newly
      # created collector therefore won't be picked by the compiler if
      # another active collector already exists for the account. The
      # caller — operator or AI agent — needs that signal to decide
      # whether to disable the older row.
      #
      # Heavyweight-profile-only in effect: the OvsBridgeApplier is the
      # sole consumer of the compiler's ipfix payload. Lightweight
      # (Linux-bridge) hosts ignore the field, so creating a collector
      # on a lightweight-only fleet is a no-op operationally — the row
      # exists but never gets wired anywhere. The skill does not gate on
      # profile because mixed-profile fleets need the row available for
      # the heavyweight subset.
      #
      # Phase O6 of the OVS+OVN dual-profile networking roadmap.
      class SdwanIpfixCollectorComposeExecutor
        DEFAULT_SAMPLING_RATE = 1
        PORT_MIN = 1
        PORT_MAX = 65_535

        def self.descriptor
          {
            name: "sdwan_ipfix_collector_compose",
            description: "Register an IPFIX collector for an account so the topology compiler can stamp ipfix exporter config onto every heavyweight (ovs-kind) HostBridge in the per-host payload. Idempotent on (account, name). Composes Sdwan::IpfixCollector.",
            category: "devops",
            inputs: {
              name: { type: "string", required: true,
                      description: "Display name for the collector — unique per account; reused on re-execution" },
              host: { type: "string", required: true,
                      description: "Collector host (IPv4, IPv6, or hostname). IPv6 addresses are bracketed automatically when emitted to ovs-vsctl." },
              port: { type: "integer", required: true,
                      description: "Collector UDP port (#{PORT_MIN}-#{PORT_MAX})" },
              sampling_rate: { type: "integer", required: false, default: DEFAULT_SAMPLING_RATE,
                               description: "Sampling rate (1 = export every flow). Ignored when re-using an existing collector." },
              dry_run: { type: "boolean", required: false, default: false,
                         description: "Plan only — no Sdwan::IpfixCollector row is persisted" }
            },
            outputs: {
              dry_run: :boolean,
              planned_actions: [ :object ],
              outputs: {
                ipfix_collector_id: :string,
                created: :boolean,
                name: :string,
                target_endpoint: :string,
                sampling_rate: :integer,
                state: :string,
                is_winning_collector: :boolean
              },
              failures: [ :object ],
              partial: :boolean
            },
            rollback: :rollback_sdwan_ipfix_collector_compose,
            requires_approval: false,
            blast_radius: :low
          }
        end

        def initialize(account:, agent: nil, user: nil)
          @account = account
          @agent = agent
          @user = user
        end

        def execute(name:, host:, port:, sampling_rate: DEFAULT_SAMPLING_RATE,
                    dry_run: false, **_extras)
          name_str = name.to_s.strip
          return failure("name is required") if name_str.empty?

          host_str = host.to_s.strip
          return failure("host is required") if host_str.empty?

          port_int = port.to_i
          unless port_int.between?(PORT_MIN, PORT_MAX)
            return failure("port must be between #{PORT_MIN} and #{PORT_MAX}")
          end

          sampling_int = sampling_rate.to_i
          return failure("sampling_rate must be >= 1") if sampling_int < 1

          existing = ::Sdwan::IpfixCollector.for_account(@account).find_by(name: name_str)

          if dry_run
            return success(
              dry_run: true,
              planned_actions: build_plan(name: name_str, host: host_str, port: port_int,
                                          sampling: sampling_int, creating: existing.nil?),
              outputs: {
                ipfix_collector_id: existing&.id,
                created: existing.nil?,
                name: name_str,
                target_endpoint: existing&.target_endpoint || projected_endpoint(host: host_str, port: port_int),
                sampling_rate: existing&.sampling_rate || sampling_int,
                state: existing&.state || "active",
                is_winning_collector: project_winning(existing: existing)
              },
              failures: [],
              partial: false
            )
          end

          run_execute(name: name_str, host: host_str, port: port_int,
                      sampling: sampling_int, existing: existing)
        rescue StandardError => e
          Rails.logger.error("[SdwanIpfixCollectorComposeExecutor] #{e.class}: #{e.message}")
          failure(e.message)
        end

        # Rollback: destroy only when this call newly created the row.
        # Pre-existing collectors are left alone since other state may
        # depend on them (compiler selection, dashboards, alerts).
        def rollback_sdwan_ipfix_collector_compose(ipfix_collector_id: nil, created: false, **_extras)
          return { success: true, errors: [] } unless created
          return { success: true, errors: [] } if ipfix_collector_id.blank?

          collector = ::Sdwan::IpfixCollector.where(account_id: @account.id).find_by(id: ipfix_collector_id)
          return { success: true, errors: [] } unless collector

          begin
            collector.destroy!
            { success: true, errors: [] }
          rescue StandardError => e
            { success: false, errors: [ { resource: "ipfix_collector", id: ipfix_collector_id, error: e.message } ] }
          end
        end

        private

        def run_execute(name:, host:, port:, sampling:, existing:)
          if existing
            return success(
              dry_run: false,
              planned_actions: [ { step: "reuse_collector", collector_id: existing.id, name: name } ],
              outputs: {
                ipfix_collector_id: existing.id,
                created: false,
                name: existing.name,
                target_endpoint: existing.target_endpoint,
                sampling_rate: existing.sampling_rate,
                state: existing.state,
                is_winning_collector: winning?(existing)
              },
              failures: [],
              partial: false
            )
          end

          begin
            collector = ::Sdwan::IpfixCollector.create!(
              account_id: @account.id,
              name: name,
              host: host,
              port: port,
              sampling_rate: sampling,
              state: "active"
            )
          rescue StandardError => e
            return failure_with_partial("create_collector", e.message)
          end

          success(
            dry_run: false,
            planned_actions: [
              { step: "create_collector", collector_id: collector.id,
                name: collector.name, target_endpoint: collector.target_endpoint }
            ],
            outputs: {
              ipfix_collector_id: collector.id,
              created: true,
              name: collector.name,
              target_endpoint: collector.target_endpoint,
              sampling_rate: collector.sampling_rate,
              state: collector.state,
              is_winning_collector: winning?(collector)
            },
            failures: [],
            partial: false
          )
        end

        def build_plan(name:, host:, port:, sampling:, creating:)
          if creating
            [ { step: "create_collector", name: name,
                target_endpoint: projected_endpoint(host: host, port: port),
                sampling_rate: sampling } ]
          else
            [ { step: "reuse_collector", name: name } ]
          end
        end

        # Mirrors IpfixCollector#target_endpoint for plan-mode reporting
        # so dry-run audit logs surface the same wire-format string the
        # live path will hand to ovs-vsctl. Keep in sync with the model.
        def projected_endpoint(host:, port:)
          bracketed = host.include?(":") ? "[#{host}]" : host
          "#{bracketed}:#{port}"
        end

        # The topology compiler picks the oldest active collector per
        # account when stamping the ipfix payload onto OVS bridges. This
        # mirror tells the caller whether the row in question is the one
        # the compiler will actually use.
        def winning?(collector)
          return false unless collector
          return false if collector.disabled?

          oldest = ::Sdwan::IpfixCollector.for_account(@account).active.order(:created_at).first
          oldest&.id == collector.id
        end

        # Dry-run variant of winning? — when no row exists yet, the new
        # one would win iff there's no active collector already.
        def project_winning(existing:)
          return winning?(existing) if existing

          ::Sdwan::IpfixCollector.for_account(@account).active.empty?
        end

        def failure_with_partial(step, msg)
          {
            success: true,
            requires_approval: false,
            data: {
              dry_run: false,
              planned_actions: [],
              outputs: {
                ipfix_collector_id: nil,
                created: false,
                name: nil,
                target_endpoint: nil,
                sampling_rate: nil,
                state: nil,
                is_winning_collector: false
              },
              failures: [ { step: step, error: msg } ],
              partial: false
            }
          }
        end

        def success(payload)
          { success: true, requires_approval: false, data: payload }
        end

        def failure(msg)
          { success: false, error: msg }
        end
      end
    end
  end
end
