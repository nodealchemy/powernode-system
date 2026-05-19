# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Composer-of-composers — orchestrates the three SDWAN composition
      # primitives in dependency order:
      #
      #   SdwanHostBridgeComposeExecutor       (always; both profiles)
      #     → SdwanOvnComposeTopologyExecutor  (when ovn_topology supplied;
      #                                         heavyweight only)
      #       → SdwanIpfixCollectorComposeExecutor
      #                                        (when ipfix_collector supplied;
      #                                         heavyweight in effect)
      #
      # Returns a unified outcome with each sub-skill's structured `:data`
      # payload nested under `outputs`. Sub-failures are collected, never
      # short-circuited — the operator may want to retry just the failing
      # phase rather than redo everything.
      #
      # Rollback is delegation, not re-implementation: the orchestrator's
      # rollback handler calls each sub-executor's rollback in reverse
      # order, threading through the same payload shapes the sub-skills
      # produced. This keeps the rollback semantics canonical (each
      # sub-executor owns its own teardown order) while still giving the
      # operator one-call undo.
      #
      # Phase O6 of the OVS+OVN dual-profile networking roadmap.
      class SdwanComposeFullTopologyExecutor < BaseSkillExecutor
        skill_descriptor(
          name: "sdwan_compose_full_topology",
          description: "Orchestrate the three SDWAN composition primitives (HostBridge, OVN, IPFIX) in one tool call. Composes SdwanHostBridgeComposeExecutor + SdwanOvnComposeTopologyExecutor + SdwanIpfixCollectorComposeExecutor.",
          category: "devops",
          inputs: {
            host_node_instance_ids: { type: "array", required: true,
                                      description: "System::NodeInstance ids — passed through to host_bridge_compose" },
            kind: { type: "string", required: false,
                    description: "Optional explicit bridge kind override (linux | ovs) — passed through to host_bridge_compose" },
            ovn_topology: { type: "object", required: false,
                            description: "Optional OVN composition payload: {nb_db_endpoint, sb_db_endpoint, northd_host?, switches} — when supplied, runs sdwan_ovn_compose_topology" },
            ipfix_collector: { type: "object", required: false,
                               description: "Optional IPFIX collector payload: {name, host, port, sampling_rate?} — when supplied, runs sdwan_ipfix_collector_compose" },
            dry_run: { type: "boolean", required: false, default: false,
                       description: "Plan only — invokes each sub-skill in dry_run mode" }
          },
          outputs: {
            dry_run: :boolean,
            planned_actions: [ :object ],
            outputs: {
              host_bridges: :object,
              ovn: :object,
              ipfix: :object
            },
            failures: [ :object ],
            partial: :boolean
          },
          rollback: :rollback_sdwan_compose_full_topology,
          blast_radius: :medium
        )

        binds_to "System Topology Designer"

        # Rollback: delegate to each sub-executor's rollback in reverse
        # dependency order (ipfix → ovn → bridges). Each sub-executor owns
        # the canonical teardown semantics for its own resources; the
        # orchestrator just threads the payload shape through.
        def rollback_sdwan_compose_full_topology(host_bridges: nil, ovn: nil, ipfix: nil, **_extras)
          errors = []

          if ipfix.present?
            sub = symbolize(ipfix)[:outputs] || {}
            r = ipfix_executor.rollback_sdwan_ipfix_collector_compose(
              ipfix_collector_id: sub[:ipfix_collector_id],
              created: sub[:created]
            )
            errors.concat(Array(r[:errors])) unless r[:success]
          end

          if ovn.present?
            sub = symbolize(ovn)[:outputs] || {}
            r = ovn_executor.rollback_sdwan_ovn_compose_topology(
              ovn_deployment_id: sub[:ovn_deployment_id],
              logical_switch_ids: sub[:logical_switch_ids] || [],
              logical_switch_port_ids: sub[:logical_switch_port_ids] || [],
              created_deployment: sub[:created_deployment]
            )
            errors.concat(Array(r[:errors])) unless r[:success]
          end

          if host_bridges.present?
            sub = symbolize(host_bridges)[:outputs] || {}
            r = bridge_executor.rollback_sdwan_host_bridge_compose(
              allocations: sub[:allocations] || []
            )
            errors.concat(Array(r[:errors])) unless r[:success]
          end

          { success: errors.empty?, errors: errors }
        end

        protected

        def perform(host_node_instance_ids:, kind: nil, ovn_topology: nil,
                    ipfix_collector: nil, dry_run: false, **_extras)
          planned_actions = []
          failures = []
          outputs = { host_bridges: nil, ovn: nil, ipfix: nil }

          # Step 1 — bridges (always runs).
          br_result = bridge_executor.execute(
            host_node_instance_ids: host_node_instance_ids,
            kind: kind,
            dry_run: dry_run
          )
          if br_result[:success]
            outputs[:host_bridges] = br_result[:data]
            planned_actions << { step: "host_bridge_compose",
                                 bridge_count: br_result[:data][:bridge_count] }
          else
            failures << { step: "host_bridge_compose", error: br_result[:error] }
          end

          # Step 2 — OVN topology (only when supplied).
          if ovn_topology.present?
            ovn_args = symbolize(ovn_topology).merge(dry_run: dry_run)
            ovn_result = ovn_executor.execute(**ovn_args)
            if ovn_result[:success]
              outputs[:ovn] = ovn_result[:data]
              planned_actions << { step: "ovn_compose_topology",
                                   switch_count: ovn_result[:data][:switch_count],
                                   port_count: ovn_result[:data][:port_count] }
            else
              failures << { step: "ovn_compose_topology", error: ovn_result[:error] }
            end
          end

          # Step 3 — IPFIX collector (only when supplied).
          if ipfix_collector.present?
            ipfix_args = symbolize(ipfix_collector).merge(dry_run: dry_run)
            ipfix_result = ipfix_executor.execute(**ipfix_args)
            if ipfix_result[:success]
              outputs[:ipfix] = ipfix_result[:data]
              planned_actions << { step: "ipfix_collector_compose",
                                   target_endpoint: ipfix_result[:data][:outputs][:target_endpoint] }
            else
              failures << { step: "ipfix_collector_compose", error: ipfix_result[:error] }
            end
          end

          success(
            dry_run: dry_run,
            planned_actions: planned_actions,
            outputs: outputs,
            failures: failures,
            partial: failures.any? && outputs.values.any?(&:present?)
          )
        end

        private

        # Each sub-executor gets a fresh instance per call so the
        # orchestrator can run on the same account/agent/user context
        # without sharing mutable state between sub-skill invocations.
        def bridge_executor
          @bridge_executor ||= SdwanHostBridgeComposeExecutor.new(account: @account, agent: @agent, user: @user)
        end

        def ovn_executor
          @ovn_executor ||= SdwanOvnComposeTopologyExecutor.new(account: @account, agent: @agent, user: @user)
        end

        def ipfix_executor
          @ipfix_executor ||= SdwanIpfixCollectorComposeExecutor.new(account: @account, agent: @agent, user: @user)
        end

        # AI tool-call payloads arrive as string-keyed hashes from the MCP
        # transport but Ruby keyword splat needs symbol keys. This is the
        # boundary where we normalize for sub-executor invocation.
        def symbolize(h)
          return {} unless h.is_a?(Hash)

          h.each_with_object({}) { |(k, v), acc| acc[k.to_sym] = v }
        end
      end
    end
  end
end
