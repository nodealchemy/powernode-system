# frozen_string_literal: true

module Api
  module V1
    module System
      module NodeApi
        # Status reporting endpoint for node instances
        # Allows instances to report their status and receive commands
        class StatusController < BaseController
          # GET /api/v1/system/node_api/status
          # Get current instance status
          def show
            render_success(
              instance: serialize_instance_status,
              node: serialize_node_status,
              pending_tasks: pending_operations_count
            )
          end

          # POST /api/v1/system/node_api/status/report
          # Report instance status update
          def report
            status = params[:status]
            # to_unsafe_h: this is agent-reported telemetry stored verbatim as a
            # jsonb document, not attribute assignment — and it must be a plain
            # Hash for #to_json below, since Parameters does not serialize to
            # the object shape the column expects.
            raw_metrics = params[:metrics]
            metrics = raw_metrics.respond_to?(:to_unsafe_h) ? raw_metrics.to_unsafe_h : (raw_metrics || {})

            # Validate status
            unless ::System::NodeInstance::STATUSES.include?(status)
              return render_error("Invalid status: #{status}")
            end

            # Update instance status
            current_instance.update!(status: status)

            # Config is a SHARED document. It is written from several
            # independent request cycles — the operator API, this endpoint, and
            # the per-heartbeat telemetry writers (System::BootLkgStateWriter,
            # System::ModuleVerifyStateWriter, Sdwan::AgentApplyStateWriter) —
            # so a read-modify-write of the whole jsonb from here silently
            # erases whatever another writer stored between the moment this
            # request loaded the row and the moment it saved. All three of
            # those writers already defend themselves with a jsonb UPDATE that
            # never reads the rest of the document; BootLkgStateWriter's
            # #merge_config_key! comment names THIS endpoint as a writer it is
            # guarding against. It is the last one still clobbering.
            #
            # `||` is a shallow merge performed by Postgres against the CURRENT
            # row, so only these two keys are touched and no concurrent
            # telemetry write is lost. Both keys are replaced wholesale, which
            # is the intended semantics for each.
            ::System::NodeInstance.where(id: current_instance.id).update_all([
              "config = COALESCE(config, '{}'::jsonb) || ?::jsonb",
              { "last_report" => Time.current.iso8601, "metrics" => metrics }.to_json
            ])

            # Check for pending operations
            pending = pending_tasks

            render_success(
              status_updated: true,
              current_status: current_instance.status,
              pending_tasks: pending.map { |o| serialize_task(o) }
            )
          end

          # POST /api/v1/system/node_api/status/heartbeat
          #
          # Body (from powernode-agent's runtime.HeartbeatPayload):
          #   boot_id, agent_version, architecture, uptime_seconds,
          #   module_digests (hash of module_id → oci_digest), mount_state,
          #   load_average, memory_free_kb, booted_image_git_sha,
          #   sdwan_state (per-network applier outcomes — see
          #   Sdwan::AgentApplyStateWriter), sdwan_ovn_state,
          #   module_verify_state (see System::ModuleVerifyStateWriter),
          #   booted_from_lkg / lkg_age_seconds / lkg_present /
          #   lkg_confirmed_at / lkg_module_count / boot_incomplete /
          #   pivot_confinement_omitted (see System::BootLkgStateWriter)
          #
          # Persists into the NodeInstance's M0.M runtime telemetry columns
          # (last_heartbeat_at, agent_version, boot_id, running_module_digests,
          # architecture, booted_image_git_sha) via the model's record_heartbeat!
          # method.
          def heartbeat
            digests = params[:module_digests]
            digests = digests.to_unsafe_h if digests.respond_to?(:to_unsafe_h)
            # Captured BEFORE record_heartbeat! stamps last_heartbeat_at: "has
            # this instance ever heartbeated" is the discriminator that keeps
            # network-profile auto-classification (below) off the legacy fleet.
            first_contact = current_instance.last_heartbeat_at.nil?
            current_instance.record_heartbeat!(
              agent_version:        params[:agent_version].presence || "unknown",
              boot_id:              params[:boot_id].presence       || "unknown",
              module_digests:       digests || {},
              architecture:         params[:architecture],
              booted_image_git_sha: params[:booted_image_git_sha]
            )

            # Record kernel-capability detection from the agent — used by
            # ModulesController#show to pick which artifact format
            # (composefs vs squashfs) to surface in the manifest
            # response. Empty / absent payload is fine; the helper
            # short-circuits and the existing capabilities row stays.
            caps = params[:node_capabilities]
            caps = caps.to_unsafe_h if caps.respond_to?(:to_unsafe_h)
            current_instance.record_capabilities!(caps) if caps.present?

            # IMP-57e9a90598ee — first-heartbeat network-profile
            # classification. record_heartbeat! above just persisted the
            # agent-observed architecture, which is the last fact
            # suggest_network_profile needs; this is therefore the first
            # moment the platform can CLASSIFY rather than guess. Runs only
            # on the instance's FIRST heartbeat ever (first_contact, captured
            # above) and only when that heartbeat will transition it into
            # running — so a legacy host rebooting never auto-classifies (see
            # the method's guards: never an already-running instance, never
            # over an operator declaration, never a demotion). Wrapped so a
            # classification bug cannot bounce telemetry.
            begin
              current_instance.classify_network_profile!(first_contact: first_contact)
            rescue StandardError => e
              Rails.logger.warn("[StatusController] network profile classification failed for #{current_instance.id}: #{e.class}: #{e.message}")
            end

            # IMP-57e9a90598ee — the agent's OVN NB replay observation
            # (manager.go OvnNbStatus, previously computed every tick and
            # thrown away) plus the control-plane NB probe drive the
            # account's Sdwan::OvnDeployment lifecycle. The reconciler is
            # observation-only: no block + nothing probeable = no change.
            # Wrapped so an OVN reconcile bug cannot bounce telemetry.
            begin
              ovn_obs = params[:sdwan_ovn_state]
              ovn_obs = ovn_obs.to_unsafe_h if ovn_obs.respond_to?(:to_unsafe_h)
              ::Sdwan::Ovn::DeploymentReconciler.reconcile!(
                instance: current_instance,
                nb_observation: ovn_obs.presence
              )
            rescue StandardError => e
              Rails.logger.warn("[StatusController] OVN deployment reconcile failed for #{current_instance.id}: #{e.class}: #{e.message}")
            end

            # IMP-da1b772c2596 — the agent's SDWAN APPLY observation. The
            # producer has shipped `sdwan_state` since the SDWAN manager
            # existed (and per-subsystem applier outcomes since 28460bbb) and
            # NOTHING on the server read the key, so a node whose nftables /
            # vrf / bridge apply failed on every tick was indistinguishable
            # from one that applied cleanly — the platform scored "served" as
            # "applied". Absent block ⇒ nothing written (absence stays
            # absence; System::Fleet::Sensors::SdwanApplyHealthSensor reads it
            # as NOT MEASURED, never as healthy). Wrapped so an ingest bug
            # cannot bounce telemetry, exactly like the OVN block above.
            begin
              apply_obs = params[:sdwan_state]
              apply_obs = apply_obs.to_unsafe_h if apply_obs.respond_to?(:to_unsafe_h)
              ::Sdwan::AgentApplyStateWriter.write!(
                instance: current_instance,
                payload:  apply_obs
              )
            rescue StandardError => e
              Rails.logger.warn("[StatusController] sdwan apply state ingest failed for #{current_instance.id}: #{e.class}: #{e.message}")
            end

            # IMP-3855ff9908f2 — the agent's `verify:` PROBE observation. The
            # platform can prove it SERVED a module and the agent can prove it
            # MOUNTED one; neither says whether the capability the module
            # exists to provide is reachable on the node afterwards. That
            # answer exists only on the node. Absent block => nothing written
            # (absence stays absence; ModuleVerifyFailedSensor reads it as NOT
            # MEASURED, never as verified). Wrapped so an ingest bug cannot
            # bounce telemetry, exactly like the two blocks above.
            begin
              verify_obs = params[:module_verify_state]
              verify_obs = verify_obs.to_unsafe_h if verify_obs.respond_to?(:to_unsafe_h)
              ::System::ModuleVerifyStateWriter.write!(
                instance: current_instance,
                payload:  verify_obs
              )
            rescue StandardError => e
              Rails.logger.warn("[StatusController] module verify state ingest failed for #{current_instance.id}: #{e.class}: #{e.message}")
            end

            # IMP-b8d5cfa33b79 — the agent's BOOT / LKG telemetry. Seven
            # top-level keys the agent has shipped on every heartbeat since #39
            # (lkg_present / lkg_confirmed_at / lkg_module_count — the ARM
            # telemetry an operator needs before #14 pulls a node's control
            # plane — plus booted_from_lkg, lkg_age_seconds, boot_incomplete and
            # pivot_confinement_omitted), and NOTHING on the server read any of
            # them: a node surviving on a frozen composition, or one not armed
            # with an LKG at all, was indistinguishable from a healthy one.
            #
            # Every field is Go `omitempty`, so a missing key is ingested as
            # UNREPORTED, never as a measured false — see
            # System::BootLkgStateWriter. None of the seven present ⇒ nothing
            # written (absence stays absence). Wrapped so an ingest bug cannot
            # bounce telemetry, exactly like the three blocks above.
            begin
              boot_obs = params.slice(*::System::BootLkgStateWriter::WIRE_KEYS)
              boot_obs = boot_obs.to_unsafe_h if boot_obs.respond_to?(:to_unsafe_h)
              ::System::BootLkgStateWriter.write!(
                instance: current_instance,
                payload:  boot_obs
              )
            rescue StandardError => e
              Rails.logger.warn("[StatusController] boot LKG state ingest failed for #{current_instance.id}: #{e.class}: #{e.message}")
            end

            # Runtime metrics (IMP-938ee27f4921): mount_state / load_average /
            # memory_free_kb / uptime_seconds have always been sent and never
            # read, while ProjectMetricsCollector named this exact source for
            # memory_pct and reported `unavailable` forever. None of the four
            # present => nothing written, so a pre-feature agent stays
            # distinguishable from a reporting one. Wrapped like the blocks
            # above so an ingest bug cannot bounce telemetry.
            begin
              runtime_obs = params.slice(*::System::RuntimeMetricsWriter::WIRE_KEYS)
              runtime_obs = runtime_obs.to_unsafe_h if runtime_obs.respond_to?(:to_unsafe_h)
              ::System::RuntimeMetricsWriter.write!(
                instance: current_instance,
                payload:  runtime_obs
              )
            rescue StandardError => e
              Rails.logger.warn("[StatusController] runtime metrics ingest failed for #{current_instance.id}: #{e.class}: #{e.message}")
            end

            # Boot-image upgrade reconcile (campaign 019f505f inc 2): the node
            # reboots mid-task, so the agent's /complete is unreliable — the
            # authoritative success signal is this post-reboot heartbeat's
            # booted_image_git_sha matching the upgrade target. Cheap no-op when
            # the instance has no in-flight upgrade_boot_image task.
            ::System::BootImage::UpgradeReconciler.reconcile!(instance: current_instance)

            # restart_after_update: this heartbeat is the exact moment the
            # platform learns what the instance has actually MATERIALIZED, so
            # it is the only safe place to decide that a dependent service now
            # needs recycling. A module declaring `services: []` never triggers
            # the agent's own restart path (it restarts only services whose
            # unit content drifts), so without this its new code sits on disk
            # while the running process serves the previous version. Cheap
            # no-op when nothing declares the field; never raises into the
            # heartbeat. See System::RestartAfterUpdate.
            ::System::RestartAfterUpdate.reconcile!(instance: current_instance)

            # Transition pending → running on first heartbeat post-enrollment.
            current_instance.mark_running! if current_instance.may_mark_running?

            # Slice 7 pool promotion — a heartbeat is the platform's only
            # evidence that a pool-provisioned instance actually enrolled
            # and is alive, so it's the natural trigger to flip a
            # "warming" member to "ready" (acquirable). Previously nothing
            # called NodeInstance#mark_pool_ready! anywhere, so every
            # pool-provisioned member sat in "warming" forever regardless
            # of how healthy it was. See NodeInstance#promote_pool_ready!
            # for the idempotency guard + FleetEvent emission.
            current_instance.promote_pool_ready!

            render_success(
              acknowledged:      true,
              server_time:       Time.current.iso8601,
              next_poll_seconds: 30
            )
          end

          # GET /api/v1/system/node_api/status/operations
          # Get pending operations for this instance
          def tasks
            operations = pending_tasks.order(created_at: :asc)

            render_success(
              tasks: operations.map { |o| serialize_operation_full(o) },
              count: operations.size
            )
          end

          # GET /api/v1/system/node_api/status/tasks/:id
          # Show a single task by id. Used by the agent's task lease
          # loop crash-recovery path: on restart, the agent walks its
          # local inflight state file and queries the platform for
          # each entry to decide whether to re-execute (non-terminal)
          # or drop (complete/failed/cancelled).
          def show_task
            operation = current_instance.tasks.find(params[:id])
            render_success(task: serialize_operation_full(operation))
          rescue ActiveRecord::RecordNotFound
            render_record_not_found("Operation")
          end

          # POST /api/v1/system/node_api/status/operations/:id/ack
          # Acknowledge operation receipt. NOTE: 'acknowledged' is NOT a
          # valid status (System::Task::STATUSES has pending/scheduled/
          # running/complete/failed/aborted/cancelled). The earlier impl
          # transitioned to status="acknowledged" which raised a
          # validation error and bubbled out as 422 — the agent's
          # post-poll ack step would fail, blocking task execution. We
          # now just append an event record without touching status;
          # the agent will transition pending → running through its own
          # update when it actually starts executing.
          def acknowledge_task
            operation = current_instance.tasks.find(params[:id])

            # Transition pending/scheduled -> running so the subsequent complete
            # (which requires the running state) succeeds. The agent's task loop
            # does acknowledge -> execute -> complete; this acknowledge IS the
            # start signal. Previously it only appended an event and left the
            # task pending, so every agent-executed task (a2a_call, etc.) failed
            # to complete ("cannot be completed from pending state").
            operation.start! if operation.may_start?

            render_success(
              task: serialize_task(operation),
              acknowledged: true
            )
          rescue ActiveRecord::RecordNotFound
            render_record_not_found("Operation")
          end

          # POST /api/v1/system/node_api/status/operations/:id/complete
          # Report operation completion
          def complete_task
            operation = current_instance.tasks.find(params[:id])

            # Boot-image upgrade completion is authoritative ONLY via the
            # post-reboot heartbeat (BootImage::UpgradeReconciler) — the node
            # reboots mid-task, so the agent's /complete races the shutdown and,
            # if it lands, would mark the task complete BEFORE we know the node
            # actually booted the new image (a false success on a failed/rolled-
            # back upgrade). Acknowledge the agent's report but DO NOT complete;
            # the reconciler transitions it when booted_image_git_sha matches.
            if operation.command == "upgrade_boot_image"
              operation.add_event("agent_reported", params[:message].to_s.presence || "reboot initiated") if operation.respond_to?(:add_event)
              return render_success(task: serialize_task(operation), completed: false,
                                    deferred_to: "post_reboot_heartbeat")
            end

            unless operation.running?
              return render_error("Operation cannot be completed from #{operation.status} state")
            end

            result = params[:result] || {}
            message = params[:message] || "Completed by instance"

            # System::Task has no `result` column — the handler's result rides the
            # completed event so it stays inspectable without a schema change.
            operation.update!(
              status: "complete",
              progress: 100,
              completed_at: Time.current,
              events: (operation.events || []) << {
                type: "completed",
                message: message,
                result: result,
                timestamp: Time.current.iso8601
              }
            )

            render_success(
              task: serialize_task(operation),
              completed: true
            )
          rescue ActiveRecord::RecordNotFound
            render_record_not_found("Operation")
          end

          # POST /api/v1/system/node_api/status/operations/:id/fail
          # Report operation failure
          def fail_task
            operation = current_instance.tasks.find(params[:id])

            # A restart_after_update task that settle! completed was completed
            # on an INFERENCE (the reporting channel dropped, which is usually
            # evidence the restart ran), not on the agent's own report. If the
            # agent later manages to report a genuine failure, that is real
            # evidence and must win over the inference — otherwise a restart
            # that stopped the unit and failed to bring it back is recorded as
            # a success. Every other terminal state stays un-overridable.
            settled = ::System::RestartAfterUpdate.settled?(operation)
            unless operation.pending? || operation.running? ||
                   operation.status == "acknowledged" || settled
              return render_error("Operation cannot be marked as failed from #{operation.status} state")
            end

            error_message = params[:error_message] || "Failed by instance"

            operation.update!(
              status: "failed",
              completed_at: Time.current,
              error_message: error_message,
              events: (operation.events || []) << {
                type: "failed",
                message: error_message,
                timestamp: Time.current.iso8601
              }
            )

            render_success(
              task: serialize_task(operation),
              failed: true
            )
          rescue ActiveRecord::RecordNotFound
            render_record_not_found("Operation")
          end

          private

          def serialize_instance_status
            {
              id: current_instance.id,
              name: current_instance.name,
              status: current_instance.status,
              variety: current_instance.variety,
              last_heartbeat: current_instance.config&.dig("last_heartbeat"),
              last_report: current_instance.config&.dig("last_report"),
              metrics: current_instance.config&.dig("metrics")
            }
          end

          def serialize_node_status
            {
              id: current_node.id,
              name: current_node.name,
              worker_assigned: current_node.worker_id.present?
            }
          end

          # Everything this returns is handed to the agent, which re-executes
          # it: tasks/loop.go tick() does NOT filter by status, and its only
          # re-entry guard is the in-memory `isInflight` set that processTask's
          # defer clears the moment the completion POST fails.
          #
          # `running` is in this list so a crashed agent can resume mid-task.
          # For a unit-scoped restart that resumption is actively harmful: the
          # one command whose completion report is reliably LOST is a restart
          # of the platform's own rails unit (it kills the process the agent
          # reports to), so re-offering it restarts the platform every ~30s
          # forever. RestartAfterUpdate.offerable withholds exactly those;
          # every other command's behaviour is unchanged.
          def pending_tasks
            ::System::RestartAfterUpdate.offerable(
              current_instance.tasks.where(status: %w[pending acknowledged running])
            )
          end

          def pending_operations_count
            pending_tasks.count
          end

          def serialize_task(operation)
            {
              id: operation.id,
              command: operation.command,
              status: operation.status,
              progress: operation.progress,
              created_at: operation.created_at
            }
          end

          def serialize_operation_full(operation)
            serialize_task(operation).merge(
              options: operation.options,
              started_at: operation.started_at,
              events: operation.events || []
            )
          end
        end
      end
    end
  end
end
