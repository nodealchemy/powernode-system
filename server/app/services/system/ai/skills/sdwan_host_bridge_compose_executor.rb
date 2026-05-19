# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Composition skill — allocate per-host SDWAN bridges for a set of
      # NodeInstances. Composition shape:
      #
      #   Array<host> → N × Sdwan::HostBridgeAllocator.allocate!
      #     → per-host {host_bridge_id, bridge_name, kind, short_id, reused}
      #
      # Profile-aware: when no explicit `kind:` is supplied, the allocator
      # picks `ovs` for heavyweight-profile hosts and `linux` for
      # lightweight-profile hosts. An explicit `kind:` override always wins
      # — useful for staged rollouts where an operator wants OVS on a host
      # whose profile column still says lightweight.
      #
      # Idempotent — re-running with the same hosts returns the existing
      # bridges with `reused=true`. The allocator owns the per-host
      # SELECT FOR UPDATE concurrency guarantee; this executor is a thin
      # AI-callable wrapper that adds account scoping, an audit log, and a
      # rollback that releases only the bridges this call newly created.
      #
      # Phase O6 of the OVS+OVN dual-profile networking roadmap.
      class SdwanHostBridgeComposeExecutor < BaseSkillExecutor
        VALID_KINDS = ::Sdwan::HostBridge::KINDS
        MAX_HOSTS   = 100

        skill_descriptor(
          name: "sdwan_host_bridge_compose",
          description: "Allocate per-host SDWAN bridges (Linux for lightweight profile, OVS for heavyweight) for a set of NodeInstances. Composes Sdwan::HostBridgeAllocator. Idempotent.",
          category: "devops",
          inputs: {
            host_node_instance_ids: { type: "array", required: true,
                                      description: "System::NodeInstance ids to allocate bridges for (1-#{MAX_HOSTS})" },
            kind: { type: "string", required: false,
                    description: "Optional explicit bridge kind override: #{VALID_KINDS.join(' | ')}. Wins over the host's network_profile when supplied." },
            dry_run: { type: "boolean", required: false, default: false,
                       description: "Plan only — no Sdwan::HostBridge rows are persisted" }
          },
          outputs: {
            dry_run: :boolean,
            bridge_count: :integer,
            planned_actions: [ :object ],
            outputs: {
              host_bridge_ids: [ :string ],
              allocations: [ :object ]
            },
            failures: [ :object ],
            partial: :boolean
          },
          rollback: :rollback_sdwan_host_bridge_compose,
          blast_radius: :low
        )

        binds_to "System Topology Designer"

        # Rollback: release only the bridges this call newly created
        # (allocations with `reused: false`). Re-used bridges are left
        # alone since other state — VMs, taps, autonomy reconciles — may
        # depend on them. `force: true` skips the draining grace window
        # because a never-applied bridge has no in-flight tap traffic to
        # protect, so the short_id can return to the pool immediately.
        def rollback_sdwan_host_bridge_compose(allocations: [], **_extras)
          errors = []

          Array(allocations).each do |alloc|
            next if alloc[:reused] || alloc["reused"]

            bridge_id = (alloc[:host_bridge_id] || alloc["host_bridge_id"]).to_s
            next if bridge_id.empty?

            bridge = ::Sdwan::HostBridge.where(account_id: @account.id).find_by(id: bridge_id)
            next unless bridge

            begin
              ::Sdwan::HostBridgeAllocator.release!(bridge, force: true)
            rescue StandardError => e
              errors << { resource: "host_bridge", id: bridge_id, error: e.message }
            end
          end

          { success: errors.empty?, errors: errors }
        end

        protected

        def perform(host_node_instance_ids:, kind: nil, dry_run: false, **_extras)
          ids = Array(host_node_instance_ids).map(&:to_s).reject(&:empty?)
          return failure("host_node_instance_ids must contain at least one id") if ids.empty?
          return failure("host_node_instance_ids count must be <= #{MAX_HOSTS}") if ids.size > MAX_HOSTS

          if kind.present? && !VALID_KINDS.include?(kind.to_s)
            return failure("kind must be one of: #{VALID_KINDS.join(', ')}")
          end

          instances = ::System::NodeInstance.joins(:node)
                                            .where(system_nodes: { account_id: @account.id })
                                            .where(id: ids)
                                            .to_a
          if instances.size != ids.size
            missing = ids - instances.map(&:id)
            return failure("host_node_instance_id(s) not found in account: #{missing.join(', ')}")
          end

          if dry_run
            return success(
              dry_run: true,
              bridge_count: instances.size,
              planned_actions: build_plan(instances: instances, kind: kind),
              outputs: {
                host_bridge_ids: [],
                allocations: instances.map { |h| project_allocation(host: h, kind: kind) }
              },
              failures: [],
              partial: false
            )
          end

          run_execute(instances: instances, kind: kind)
        end

        private

        def run_execute(instances:, kind:)
          planned_actions = []
          failures = []
          host_bridge_ids = []
          allocations = []

          instances.each do |host|
            # Snapshot prior bridge ids for this host so we can detect
            # whether the allocator returned an existing row (reused) or
            # a freshly-minted one. The race window (another caller
            # allocating between snapshot and allocate!) is benign — the
            # allocator is idempotent, so the worst case still reports
            # a correct outcome.
            prior_ids = ::Sdwan::HostBridge.where(node_instance_id: host.id).pluck(:id).to_set

            begin
              bridge = ::Sdwan::HostBridgeAllocator.allocate!(
                host: host,
                kind: kind,
                account: @account
              )
              reused = prior_ids.include?(bridge.id)
              host_bridge_ids << bridge.id
              alloc = {
                host_node_instance_id: host.id,
                host_bridge_id: bridge.id,
                bridge_name: bridge.bridge_name,
                kind: bridge.kind,
                short_id: bridge.short_id,
                state: bridge.state,
                reused: reused
              }
              allocations << alloc
              planned_actions << { step: "allocate_bridge",
                                   host_node_instance_id: host.id,
                                   host_bridge_id: bridge.id,
                                   bridge_name: bridge.bridge_name,
                                   kind: bridge.kind,
                                   reused: reused }
            rescue StandardError => e
              failures << { step: "allocate_bridge",
                            host_node_instance_id: host.id,
                            error: e.message }
            end
          end

          finalize(planned_actions: planned_actions, failures: failures,
                   host_bridge_ids: host_bridge_ids, allocations: allocations)
        end

        def finalize(planned_actions:, failures:, host_bridge_ids:, allocations:)
          success(
            dry_run: false,
            bridge_count: host_bridge_ids.size,
            planned_actions: planned_actions,
            outputs: {
              host_bridge_ids: host_bridge_ids,
              allocations: allocations
            },
            failures: failures,
            partial: failures.any? && host_bridge_ids.any?
          )
        end

        def build_plan(instances:, kind:)
          instances.map do |h|
            {
              step: "allocate_bridge",
              host_node_instance_id: h.id,
              projected_kind: project_kind(host: h, kind: kind)
            }
          end
        end

        def project_allocation(host:, kind:)
          {
            host_node_instance_id: host.id,
            projected_kind: project_kind(host: host, kind: kind)
          }
        end

        # Mirrors HostBridgeAllocator#resolve_kind for plan-mode reporting
        # so the dry-run audit log shows the same kind the live path would
        # pick. Keep in sync with HostBridgeAllocator::PROFILE_TO_KIND.
        def project_kind(host:, kind:)
          return kind.to_s if kind.present?

          ::Sdwan::HostBridgeAllocator::PROFILE_TO_KIND.fetch(
            host.network_profile.to_s,
            ::Sdwan::HostBridgeAllocator::DEFAULT_KIND
          )
        end
      end
    end
  end
end
