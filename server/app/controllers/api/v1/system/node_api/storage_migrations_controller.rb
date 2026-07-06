# frozen_string_literal: true

module Api
  module V1
    module System
      module NodeApi
        # Agent-facing endpoint for storage migrations. The agent polls
        # /index every reconcile tick; for any approved (or in-flight)
        # migration on this instance it runs the 6-step contract:
        # mount_target → snapshot → rsync → verify → cutover → unmount_source.
        # Each state transition is reported via /progress, which is a
        # thin pass-through to System::StorageMigration#transition_to!
        # and #report_progress!.
        #
        # Authenticated via the instance JWT; current_instance is
        # provided by BaseController. Scopes to migrations where
        # node_instance_id == current_instance.id and status is
        # non-terminal — the agent never sees other instances' work
        # and never sees terminal rows (they're handled by the operator
        # via the operator-side controllers + MCP).
        #
        # Plan reference: E8.2 — agent-execution surface.
        class StorageMigrationsController < BaseController
          before_action :set_migration, only: %i[progress revert_complete cleanup_complete]

          # GET /api/v1/system/node_api/storage_migrations
          # Returns active (non-terminal) migrations assigned to this
          # instance, UNIONED with any TERMINAL migration that has a
          # pending revert/cleanup intent (increment 9) — the agent's
          # poll loop otherwise never sees terminal rows at all, but
          # revert/cleanup are only ever requested on a failed/
          # cancelled/completed-with-a-swallowed-promote migration.
          # The runner walks them in order, advancing each through the
          # contract states (or the revert/cleanup step, checked first
          # — see migration.Runner#advance).
          def index
            migrations = ::System::StorageMigration
              .where(node_instance_id: current_instance.id)
              .merge(::System::StorageMigration.active.or(::System::StorageMigration.pending_binding_intent))
              .includes(:source_volume, :target_volume)
              .order(:created_at)

            render_success(
              storage_migrations: migrations.map { |m| serialize_for_agent(m) },
              count: migrations.size
            )
          end

          # POST /api/v1/system/node_api/storage_migrations/:id/progress
          # Body: { status?, bytes_copied?, bytes_total?, bytes_verified?, note? }
          # The agent calls this on every state transition AND
          # periodically during long-running phases (syncing).
          def progress
            new_status = params[:status].to_s.presence

            if new_status
              unless @migration.can_transition_to?(new_status)
                return render_error(
                  "Illegal transition #{@migration.status} → #{new_status}",
                  status: :unprocessable_content
                )
              end
              @migration.transition_to!(
                new_status,
                message: params[:note] || "Agent reported #{new_status}",
                details: progress_details
              )
            end

            @migration.report_progress!(
              bytes_copied:   params[:bytes_copied]&.to_i,
              bytes_total:    params[:bytes_total]&.to_i,
              bytes_verified: params[:bytes_verified]&.to_i,
              note:           params[:note]
            )

            render_success(storage_migration: serialize_for_agent(@migration.reload))
          rescue ArgumentError => e
            render_error(e.message, status: :unprocessable_content)
          end

          # POST /api/v1/system/node_api/storage_migrations/:id/fail
          # Body: { reason: "..." }
          # Allows the agent to give up cleanly — caller must explain.
          def fail
            @migration = ::System::StorageMigration.find_by!(
              id: params[:id], node_instance_id: current_instance.id
            )
            @migration.mark_failed!(reason: params[:reason].to_s.presence || "agent reported failure")
            render_success(storage_migration: serialize_for_agent(@migration.reload))
          rescue ActiveRecord::RecordNotFound
            render_error("Migration not found", status: :not_found)
          end

          # POST /api/v1/system/node_api/storage_migrations/:id/revert_complete
          # Body: { status: "completed"|"failed", reason?, artifacts?: [...] }
          # The agent calls this once migration.Runner#stepRevert has
          # re-pointed the canonical mount back to source (or given up).
          def revert_complete
            if params[:status].to_s == "failed"
              @migration.revert_failed!(reason: params[:reason].to_s.presence || "agent reported revert failure")
            else
              @migration.revert_completed!(artifacts: artifact_params)
            end
            render_success(storage_migration: serialize_for_agent(@migration.reload))
          rescue ArgumentError => e
            render_error(e.message, status: :unprocessable_content)
          end

          # POST /api/v1/system/node_api/storage_migrations/:id/cleanup_complete
          # Body: { status: "completed"|"failed", reason?, artifacts?: [...] }
          # The agent calls this once migration.Runner#stepCleanup has
          # deleted the target-side scratch artifacts (or given up).
          def cleanup_complete
            if params[:status].to_s == "failed"
              @migration.cleanup_failed!(reason: params[:reason].to_s.presence || "agent reported cleanup failure")
            else
              @migration.cleanup_completed!(artifacts: artifact_params)
            end
            render_success(storage_migration: serialize_for_agent(@migration.reload))
          rescue ArgumentError => e
            render_error(e.message, status: :unprocessable_content)
          end

          private

          def set_migration
            @migration = ::System::StorageMigration.find_by!(
              id: params[:id], node_instance_id: current_instance.id
            )
          rescue ActiveRecord::RecordNotFound
            render_error("Migration not found", status: :not_found)
          end

          def progress_details
            params.permit(:bytes_copied, :bytes_total, :bytes_verified).to_h.compact
          end

          # Array-of-hash report from the agent describing exactly what
          # it touched (path, mount_point, already_clean, ...) — the
          # model turns each entry into its own audit_log line so the
          # trail names the exact artifact + actor.
          def artifact_params
            params.permit(artifacts: %i[label path mount_point already_clean mount_error note]).to_h["artifacts"] || []
          end

          # Serialize a migration for the agent's runner. We include the
          # full plan + computed source/target binding shapes the agent
          # needs to mount each volume during the preparing phase, plus
          # the canonical consumer mount point and the systemd units to
          # restart across cutover.
          def serialize_for_agent(m)
            {
              id: m.id,
              status: m.status,
              role: m.role,
              source_subpath: m.source_subpath,
              target_subpath: m.target_subpath,
              snapshot_subpath: m.snapshot_subpath,
              bytes_copied: m.bytes_copied,
              bytes_total: m.bytes_total,
              bytes_verified: m.bytes_verified,
              plan: m.plan,
              source_binding: volume_binding(m.source_volume, m.source_subpath),
              target_binding: volume_binding(m.target_volume, m.target_subpath),
              # snapshot_subpath is target-side (see StorageMigration's
              # cleanup docs) — same volume as target_binding, own
              # scratch subpath. Currently unmounted/unused by any
              # sync step (v1 has no separate snapshot phase) but
              # cleanup deletes it regardless, defensively.
              #
              # SAFETY: only emitted when snapshot_subpath is actually
              # present. volume_binding(volume, nil) would still build a
              # binding — with a blank NFS subpath, mount.ReconcileStorageVolume
              # mounts the export ROOT, not a subpath — and cleanup would
              # then `find -delete` across the WHOLE export, reaching
              # every other deployment's data on shared NFS. A blank/nil
              # snapshot_subpath (legitimately possible: the column
              # predates this field and is nullable) must never produce
              # a mountable binding.
              snapshot_binding: m.snapshot_subpath.present? ? volume_binding(m.target_volume, m.snapshot_subpath) : nil,
              # Increment 9 — set once an operator has explicitly
              # requested one via the MCP surface (revert_binding! /
              # request_cleanup!). Reachable here even when m.status is
              # terminal — see #index's pending_binding_intent union.
              revert_requested: m.metadata["revert_status"] == "requested",
              cleanup_requested: m.metadata["cleanup_status"] == "requested",
              # Canonical consumer mount point — where the consumer
              # module (e.g. postgres) reads its data from. This is the
              # path the agent re-points at the target during cutover
              # (and back to source during a revert).
              consumer_mount_point: consumer_mount_point_for(m),
              # systemd units the agent stops before umount + starts
              # after the new mount lands.
              consumer_units: consumer_units_for(m)
            }
          end

          def consumer_mount_point_for(m)
            m.node_instance&.config&.dig("storage_volume", "mount_point")
          end

          # Resolve consumer units from System::ModuleService rows
          # whose role matches the migration's role. Returns the
          # systemd unit names (typically `<service-name>.service`).
          # Falls back to the role itself when no module_service rows
          # match — operator can preconfigure this via plan.consumer_units.
          def consumer_units_for(m)
            preconfigured = Array(m.plan.dig("consumer_units"))
            return preconfigured if preconfigured.any?

            modules = ::System::NodeModule
              .joins(:module_services)
              .where(node_id: m.node_instance&.node_id, enabled: true)
              .where("system_module_services.name = ?", m.role)

            modules.flat_map do |mod|
              mod.module_services.where(name: m.role).map { |svc| "#{svc.name}.service" }
            end.uniq
          rescue StandardError => e
            Rails.logger.warn("[StorageMigrationsController#consumer_units_for] #{e.message}")
            []
          end

          # Build a binding shape the agent's mount layer understands.
          # Mirrors the shape the orchestrator stamps onto
          # NodeInstance.config["storage_volume"], so the agent can
          # reuse the same mount.ReconcileStorageVolume code path.
          # NFS connection details live on volume.config[transport]
          # (matches PlatformDeploymentOrchestrator#attach_storage_volume!).
          def volume_binding(volume, subpath)
            return nil unless volume

            transport = volume.volume_type&.volume_type.to_s
            binding = {
              volume_id: volume.id,
              volume_name: volume.name,
              transport: transport,
              subpath: subpath,
              mount_point: migration_mount_point(volume, subpath)
            }

            cfg = volume.config.is_a?(Hash) ? volume.config[transport] : nil
            case transport
            when "nfs"
              binding[:nfs] = {
                server: cfg&.dig("server"),
                export_path: cfg&.dig("export_path"),
                mount_options: cfg&.dig("mount_options").presence || "nfsvers=4.1,hard",
                subpath: subpath,
                full_export_path: cfg&.dig("server") && cfg["export_path"] ?
                                    "#{cfg['server']}:#{cfg['export_path'].chomp('/')}/#{subpath.to_s.delete_prefix('/')}" : nil
              }.compact
            when "block"
              binding[:device_name] = cfg&.dig("device_name")
            end
            binding
          end

          def migration_mount_point(volume, subpath)
            safe = subpath.to_s.tr("/", "_").delete_prefix("_")
            "/var/lib/powernode/migrations/#{volume.id}-#{safe}"
          end
        end
      end
    end
  end
end
