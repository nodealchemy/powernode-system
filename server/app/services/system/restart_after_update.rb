# frozen_string_literal: true

module System
  # `restart_after_update` — a module declares that updating IT requires
  # restarting ANOTHER module's systemd service.
  #
  # == The defect this closes
  #
  # The agent restarts a service only when that service's own unit content
  # drifts: lifecycle.AttachServices "updates unit content + restarts only
  # services whose unit file content actually changed", and the reconciler
  # re-runs it only when mount.LastAttachedManifestHashes — the SHA256 of the
  # manifest's SERVICES BLOCK — changes. A module that declares `services: []`
  # therefore never restarts anything, ever. powernode-extension-system is
  # exactly that shape: its controllers and jobs run inside hub-backend's rails
  # and hub-worker's sidekiq processes, and it owns no services of its own.
  #
  # Observed live 2026-08-16: extension v53 was built, signed, published,
  # promoted and materialized (the instance's running_module_digests for the
  # module matched the promoted oci_digest byte-for-byte), yet a 200s poll of
  # /up at 5s intervals spanning the delivery recorded ZERO non-200 responses.
  # The new code sat on disk while the running Rails process still served the
  # previous version from memory. The deploy looked complete and was inert.
  # Extension changes have only ever activated by riding along with a core
  # deploy, whose Rails restart loads them incidentally.
  #
  # == Manifest shape (optional; absent means exactly today's behaviour)
  #
  #   services: []            # unchanged
  #   restart_after_update:
  #     - module: powernode-hub-backend
  #       services: [rails]
  #     - module: powernode-hub-worker
  #       services: [sidekiq]
  #
  # Deliberately explicit rather than inferred from `dependencies.requires`:
  # the extension already requires hub-backend, but "requires" is not "must
  # restart" — some dependencies are build-time or data-only, and inferring
  # would bounce Rails on every docs-only extension change.
  #
  # == Lifecycle
  #
  #   promotion  -> arm!      stamps the PROMOTED VERSION as armed
  #   heartbeat  -> reconcile! settle! then fire!
  #
  # Promotion ARMS; it never enqueues. Enqueueing at promotion would restart
  # into the OLD files — the same ordering bug behind the two outages of
  # 2026-08-16 — because at promotion time no instance has materialized the new
  # artifact yet. fire! gates on the instance's own reported digest instead.
  #
  # == The command name is not a free choice
  #
  # The agent dispatches on the LITERAL command string (tasks.Registry#Lookup),
  # and only "restart" reaches LifecycleHandler -> systemctl restart
  # options["unit"]. But "restart" is ALSO in ExecutionDispatcher::
  # COMMAND_REGISTRY, where Runtime::ControlInstance maps it to the "reboot"
  # action and reboots the WHOLE VM through the provider adapter. Since
  # System::Task's after_commit enqueues server-side execution on create, a
  # naive restart task would reboot the VM *and* restart the unit. The
  # discriminator is DECLARED: options["scope"] is "unit" (agent) or
  # "instance" (provider), System::Task refuses a restart that declares
  # neither, and ExecutionDispatcher.restart_scope reads the declaration.
  # This producer is unit-scoped and says so.
  class RestartAfterUpdate
    # Manifest key, mirrored onto NodeModule#config by ManifestImportService.
    DECLARATION_KEY = "restart_after_update"

    # Stamped onto the PROMOTED NodeModuleVersion#config by arm!. Absent means
    # "promoted before this feature existed, or by a module that declares
    # nothing" — and must behave exactly as it does today. Keying the arm to
    # the version (not the module) is what stops a fleet-wide restart storm the
    # first time this code ships: every already-current version predates it.
    ARMED_KEY = "restart_after_update_armed_at"

    # How long an in-flight unit restart is left alone before settle! records
    # it as complete. Must comfortably exceed a systemctl restart plus the
    # target's boot (Rails returns 502 on /up for ~30s after a restart), and
    # must stay short enough that the task does not read as hung for long.
    # Floored deliberately: `"abc".to_i` is 0, and a zero grace would settle
    # every in-flight restart on the very next heartbeat — inverting the
    # safety this constant exists to provide. A bad value must fail CLOSED
    # (wait longer), never open.
    SETTLE_GRACE_FLOOR = 60
    SETTLE_GRACE = [
      (ENV["RESTART_AFTER_UPDATE_SETTLE_GRACE_SECONDS"] || 120).to_i, SETTLE_GRACE_FLOOR
    ].max.seconds

    IN_FLIGHT = %w[pending scheduled running].freeze

    Declaration = Struct.new(:module_name, :services, keyword_init: true)

    class << self
      # Parses NodeModule#config into normalized declarations. Pure: no DB, no
      # writes. Anything malformed is dropped rather than raised — the shared
      # validator (System::ModuleConfigValidator#validate_restart_after_update)
      # is the place that rejects a bad declaration, and BOTH writers run it:
      # the manifest-import path at validation time so CI catches it, and
      # node_modules#create/#update before any `config:` write reaches the
      # column (IMP-7d4c691ffe91). By the time a declaration reaches the fleet
      # it has already been through that gate; a survivor here is corrupt data, and
      # dropping it fails closed (no restart) rather than open.
      def declarations(node_module)
        raw = node_module&.config.is_a?(Hash) ? node_module.config[DECLARATION_KEY] : nil
        return [] unless raw.is_a?(Array)

        raw.filter_map do |entry|
          next unless entry.is_a?(Hash)

          name     = entry["module"].to_s
          services = Array(entry["services"]).filter_map { |s| s.to_s.presence }
          next if name.blank? || services.empty?

          Declaration.new(module_name: name, services: services.uniq)
        end
      end

      # The canonical systemd unit name, COMPUTED — never guessed. Mirrors
      # agent/internal/lifecycle/service.go UnitName(moduleID, svcName):
      # powernode-<module-id>-<service>.service. This must be derived rather
      # than assumed because a wrong unit name does not error: `systemctl
      # restart` on a nonexistent unit fails silently in a `||` chain, leaving
      # new code on disk and the old process running — which looks exactly like
      # a successful deploy (standing rule in CLAUDE.md).
      def unit_name(module_id, service_name)
        "powernode-#{module_id}-#{service_name}.service"
      end

      # Marks a freshly PROMOTED version as eligible to trigger restarts once
      # instances materialize it. Idempotent; a no-op for a module that
      # declares nothing. update_columns deliberately: NodeModule/Version
      # callbacks must not fire on what is a bookkeeping stamp.
      # Called from NodeModule#promote_to_version! — its ONLY call site in the
      # tree — which returns false (and so never reaches here) when the version
      # is already current. That placement is what makes the three cases all
      # correct:
      #
      # It is NOT reached on every move of current_version_id, and the comment
      # here used to imply it was ("the platform's single choke point for 'this
      # version is now what the fleet runs'"). Other sites write that column
      # directly and arm nothing. Do NOT take their count from this comment —
      # a count written here is exactly what rotted last time; the executable
      # census is spec/lint/node_module_current_version_write_seam_spec.rb,
      # which names each writer and the guards it skips.
      #
      # The rollback ROUTES are no longer among them. Until IMP-b7abf6c777da,
      # ModuleVersionService#rollback_to reached the column through
      # #create_version's own `update!` and armed nothing, so the
      # "ROLLBACK -> fires" row below held for the MCP rollback verb but not
      # for POST /api/v1/system/node_modules/:id/rollback. That service now
      # promotes through NodeModule#promote_to_version!
      # (module_version_service.rb, #rollback_to), so the row holds for the MCP
      # verb, the REST route and the worker-API rollback alike.
      #
      #   new publish     -> current_version moves -> fresh stamp -> fires
      #   republished tag -> already current, no move -> no re-stamp -> quiet
      #   ROLLBACK        -> current_version moves BACK -> fresh stamp -> fires
      #
      # The stamp is deliberately REFRESHED on every promotion rather than
      # written once. It feeds the dedup fingerprint, so a rollback to a
      # version whose digest was already restarted still produces a new key.
      # Without that, the recovery path is the one path that stays inert:
      # the known-good files land on disk while the bad code keeps serving.
      def arm!(node_module:, version:)
        return false if version.nil?
        return false if declarations(node_module).empty?

        config = version.config.is_a?(Hash) ? version.config.dup : {}
        version.update_columns(config: config.merge(ARMED_KEY => Time.current.iso8601))
        true
      end

      def armed?(version)
        armed_at(version).present?
      end

      def armed_at(version)
        version&.config.is_a?(Hash) ? version.config[ARMED_KEY] : nil
      end

      # Called from the heartbeat — the exact moment the platform learns what
      # an instance has actually materialized. Never raises into the heartbeat
      # path (same contract as BootImage::UpgradeReconciler).
      def reconcile!(instance:)
        new(instance: instance).reconcile!
      end

      # Withholds an in-flight unit restart from the agent's task list.
      #
      # The agent's poll loop (tasks/loop.go tick) does NOT filter by status,
      # and StatusController#pending_tasks includes `running`. Its only re-entry
      # guard is in-memory `isInflight`, which processTask's defer clears as
      # soon as the completion POST fails. So a restart whose report was lost —
      # precisely what happens when the restarted unit IS the platform — gets
      # re-offered on the next ~30s poll and re-executed. That is a restart
      # LOOP, not merely a hung task, and it is why settle! alone is not
      # enough. Scoped to unit-scoped restarts so no other command's
      # crash-recovery behaviour changes.
      # Scoped to restarts THIS feature created (the provenance key), so
      # offerable and settle! cover exactly the same set. A unit restart an
      # operator or another tool queued is never settled here, so withholding
      # it would strand it `running` — losing its crash-recovery re-offer —
      # until the task reaper fails it an hour later.
      #
      # NULLIF keeps the SQL agreeing with unit_scoped_restart?'s `.present?`:
      # an empty-string unit is not unit-scoped on either side.
      def offerable(scope)
        scope.where(
          "NOT (system_tasks.status = 'running' AND system_tasks.command = 'restart' " \
          "AND NULLIF(system_tasks.options ->> 'unit', '') IS NOT NULL " \
          "AND system_tasks.options -> '#{DECLARATION_KEY}' IS NOT NULL)"
        )
      end

      # True for a task whose completion was INFERRED by settle! rather than
      # reported by the agent. Such a task is complete on an argument, not on
      # evidence, so a late failure report must still be allowed to overrule
      # it — see StatusController#fail_task.
      def settled?(task)
        task.options.is_a?(Hash) && task.options.dig(DECLARATION_KEY, "settled_at").present?
      end
    end

    def initialize(instance:)
      @instance = instance
    end

    # Returns { settled:, enqueued: }.
    def reconcile!
      return { settled: 0, enqueued: 0 } if @instance.nil?

      { settled: settle!, enqueued: fire! }
    rescue StandardError => e
      ::Rails.logger.warn("[RestartAfterUpdate] instance=#{@instance&.id}: #{e.class}: #{e.message}")
      { settled: 0, enqueued: 0 }
    end

    private

    # === Firing (materialization-gated) ===

    def fire!
      node = @instance.node
      return 0 if node.nil?

      running = @instance.running_module_digests || {}
      return 0 if running.empty?

      attached = attached_modules(node)

      # unit => { services:, target:, triggers: [[module_id, digest], ...] }.
      # Keying the accumulator by UNIT is the deduplication: several modules
      # naming the same service collapse to one entry, so a shared rails unit
      # is restarted once rather than once per declaring module.
      planned = {}

      attached.each do |mod|
        decls = self.class.declarations(mod)
        next if decls.empty?

        version = mod.current_version
        next if version.nil?

        digest = version.oci_digest
        next if digest.blank?

        # A version promoted before this feature shipped is not armed, so it
        # cannot fire. Without this, the first heartbeat after deploy would
        # restart services for every already-materialized module at once.
        next unless self.class.armed?(version)

        # TRAP 1 — the materialization gate. Only once THIS instance reports
        # the promoted digest do the new files exist on it; restarting any
        # earlier restarts into the old ones.
        next unless running[mod.id.to_s] == digest

        decls.each do |decl|
          # A named module that is not attached to this instance is a clean
          # no-op, not an error: the same manifest ships to nodes with
          # different module sets, and hub-worker's sidekiq simply is not
          # present on a node that runs only rails.
          target = attached.find { |m| m.name == decl.module_name }
          next if target.nil?

          decl.services.each do |service|
            unit = self.class.unit_name(target.id, service)

            # TRAP 2, second half. Collapsing duplicates within this pass is
            # not enough: a platform deploy is three modules that materialize
            # on their OWN heartbeats, so without this each would queue its
            # own restart of the same rails unit and the platform would bounce
            # three times back to back.
            next if in_flight_units.include?(unit)

            entry = planned[unit] ||= { target: target, service: service, triggers: [] }
            entry[:triggers] << [ mod.id, digest, self.class.armed_at(version) ]
          end
        end
      end

      planned.sum { |unit, entry| enqueue_restart!(unit, entry) ? 1 : 0 }
    end

    # Modules actually mounted on this instance's node. There are TWO
    # pathways, and this must honour both — the same union
    # NodeApi::ModulesController#node_modules serves to the agent:
    #
    #   1. an enabled NodeModuleAssignment row (operator-attached bases), and
    #   2. dependant children (config/instance variety) created by
    #      NodeModuleAssignment#create_dependant!, which set node_id +
    #      parent_module_id and create NO assignment row at all.
    #
    # That controller carries an explicit comment that honouring only path 1
    # was a bug which made dependant children "silently absent". Repeating it
    # here would mean a declaration naming a dependant child resolves to
    # nothing and restarts nothing — reproducing the exact inert-deploy
    # failure this feature exists to remove.
    def attached_modules(node)
      assigned_ids = ::System::NodeModuleAssignment
                     .where(node_id: node.id, enabled: true)
                     .pluck(:node_module_id)

      dependant_ids = ::System::NodeModule
                      .where(node_id: node.id, enabled: true)
                      .where.not(parent_module_id: nil)
                      .pluck(:id)

      ::System::NodeModule
        .where(id: (assigned_ids + dependant_ids).uniq)
        .includes(:current_version)
        .to_a
    end

    def enqueue_restart!(unit, entry)
      triggers = entry[:triggers].sort
      ::System::Task.create!(
        account:         @instance.account,
        operable:        @instance,
        command:         "restart",
        status:          "pending",
        idempotency_key: idempotency_key(unit, triggers),
        description:     "restart_after_update: #{entry[:target].name}/#{entry[:service]} " \
                         "after #{triggers.size} module update(s)",
        options: {
          # DECLARED, never inferred. "unit" scopes this to one systemd unit on
          # the node; without the declaration ExecutionDispatcher would be left
          # guessing between that and rebooting the whole VM through the
          # provider. options["unit"] is what the agent's LifecycleHandler
          # actually reads.
          ::System::Task::RESTART_SCOPE_KEY => "unit",
          "unit" => unit,
          DECLARATION_KEY => {
            "target_module_id" => entry[:target].id,
            "service"          => entry[:service],
            "triggers"         => triggers.map do |mid, digest, armed_at|
              { "module_id" => mid, "digest" => digest, "armed_at" => armed_at }
            end
          }
        }
      )
      true
    rescue ActiveRecord::RecordNotUnique
      # Deduplication across time, enforced by the partial unique index
      # idx_system_tasks_idempotency rather than by a read-then-write race:
      # this exact (instance, unit, trigger set) was already enqueued.
      false
    rescue StandardError => e
      ::Rails.logger.warn("[RestartAfterUpdate] enqueue failed (instance=#{@instance.id}, " \
                          "unit=#{unit}): #{e.class}: #{e.message}")
      false
    end

    # Includes the triggering digests so a NEW version re-fires while a repeat
    # heartbeat carrying the same digests does not. Hashed to keep the key
    # bounded; the readable form is preserved in options for the operator.
    # Includes the ARM STAMP as well as the digest. Digest alone permanently
    # consumes the key for a version, so a rollback — which re-promotes a
    # version whose digest already fired once — would be silently suppressed
    # on the one path where inertness is most damaging.
    def idempotency_key(unit, triggers)
      seed = triggers.map { |mid, digest, armed_at| "#{mid}@#{digest}@#{armed_at}" }.join(",")
      "restart_after_update:#{@instance.id}:#{unit}:#{::Digest::SHA256.hexdigest(seed)[0, 16]}"
    end

    # Units already awaiting or undergoing a restart on this instance. Read
    # once per pass; `planned` is keyed by unit so nothing this pass creates
    # can collide with itself.
    def in_flight_units
      @in_flight_units ||= ::System::Task
                           .where(operable: @instance, command: "restart", status: IN_FLIGHT)
                           .filter_map { |t| t.options["unit"] if t.options.is_a?(Hash) }
                           .to_set
    end

    # === Settling (the self-restart hazard) ===
    #
    # On ops-hub, hub-backend's rails IS the platform. `systemctl restart` on
    # it kills the process the agent posts its Result to, and loop.go
    # processTask does NOT retry a failed Complete() — it calls OnError and
    # returns — so the task is left `running` and a SUCCESSFUL restart reads as
    # a hung one. The agent cannot be changed, so this is resolved here.
    #
    # The inference is sound because the failure modes are asymmetric:
    #
    #   - restart fails (unit missing, systemd refuses) -> the platform never
    #     went down -> the agent's Fail POST lands normally -> the task is
    #     recorded failed and settle! never sees it.
    #   - restart succeeds against the platform's own unit -> the platform
    #     bounces -> the completion POST is the one that is lost.
    #
    # So a unit restart still in flight past the grace window is one whose
    # report could not be delivered, which is evidence the restart happened.
    #
    # What this does NOT establish: that the service came back HEALTHY.
    # "complete" here means `systemctl restart` was reached and the reporting
    # channel dropped, never that the unit is serving. Post-restart health is
    # ModuleSmokeProbe's job.
    def settle!
      settled = 0
      in_flight_unit_restarts.each do |task|
        next unless settle_due?(task)

        task.add_event(
          "restart_after_update_settled",
          "completion report not received within #{SETTLE_GRACE.to_i}s; the restart of " \
          "#{task.options['unit']} took down the reporting channel, which is the evidence " \
          "it ran (a failed restart reports normally). Health is not asserted."
        ) if task.respond_to?(:add_event)
        # Marks the completion as INFERRED. The asymmetry argument above is
        # strong but not total: if the restart stopped the unit and then
        # failed to start it, the platform is down and the agent's Fail POST
        # is lost too — indistinguishable from here. Recording that this
        # completion was inferred lets a late failure report overrule it
        # instead of being rejected as "cannot fail from complete".
        provenance = (task.options[DECLARATION_KEY] || {}).merge("settled_at" => Time.current.iso8601)
        task.update_columns(options: task.options.merge(DECLARATION_KEY => provenance))
        task.complete! if task.may_complete?
        settled += 1
      end
      settled
    end

    def in_flight_unit_restarts
      ::System::Task
        .where(operable: @instance, command: "restart", status: "running")
        .select { |t| t.options.is_a?(Hash) && t.options["unit"].present? && t.options[DECLARATION_KEY].present? }
    end

    def settle_due?(task)
      anchor = task.started_at || task.updated_at || task.created_at
      anchor.present? && anchor < SETTLE_GRACE.ago
    end
  end
end
