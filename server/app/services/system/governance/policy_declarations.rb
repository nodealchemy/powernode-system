# frozen_string_literal: true

module System
  module Governance
    # SINGLE AUTHORITY for the governance rows the code declares.
    #
    # These used to live as local hashes inside the seed files, which made them
    # unreadable from anywhere except a seed run — and `db:seed` is first-boot
    # only (rails-start.sh gates it behind a durable `.db-initialized` marker),
    # so a policy added after an install's first boot never reached it. Measured
    # on live ops-hub 2026-08-24: nine policies added to seeds afterwards had
    # never landed, including `system.module_verify_investigate`, whose sensors
    # had been firing into a silently-blocked arm since the day they shipped.
    #
    # Declaring them here lets PolicyReconciler assert the invariant "every
    # governance row the code declares exists in the RUNNING database" without
    # executing a seed — which matters because the seed path is DESTRUCTIVE (see
    # PolicyReconciler's header) and must not run on an established install.
    #
    # The seed consumes this same constant, so first boot and every later
    # reconcile agree by construction rather than by two lists staying in sync.
    module PolicyDeclarations
      # Operator-path rows for System::Task commands: scope "global", no agent,
      # no user. Verbs are the OPERATOR's default, deliberately conservative for
      # anything that destroys or overwrites state.
      #
      # NOTE (IMP-944567d41689): this key set currently disagrees with
      # System::Task::COMMANDS in both directions — it declares categories for
      # commands the model refuses to insert, and omits real commands. That
      # drift is tracked separately; this constant records what is declared
      # TODAY so the reconciler is honest about the current contract rather than
      # silently repairing a vocabulary question it has no mandate to decide.
      MANUAL_OPERATION_POLICIES = {
        "system.task.start" => "auto_approve",
        "system.task.stop" => "auto_approve",
        "system.task.restart" => "auto_approve",
        "system.task.reboot" => "auto_approve",
        "system.task.terminate" => "require_approval",        # destroys instance
        "system.task.provision" => "notify_and_proceed",      # creates infra
        "system.task.deprovision" => "require_approval",      # destroys infra
        "system.task.associate_public_ip" => "auto_approve",
        "system.task.disassociate_public_ip" => "auto_approve",
        "system.task.create_volume" => "notify_and_proceed",
        "system.task.delete_volume" => "require_approval",
        "system.task.attach_volume" => "auto_approve",
        "system.task.detach_volume" => "notify_and_proceed",
        "system.task.create_snapshot" => "auto_approve",
        "system.task.delete_snapshot" => "require_approval",
        "system.task.restore_snapshot" => "require_approval", # rolls back state
        "system.task.create_network" => "notify_and_proceed",
        "system.task.delete_network" => "require_approval",
        "system.task.sync" => "auto_approve",
        "system.task.sync_modules" => "auto_approve",
        "system.task.apply_config" => "notify_and_proceed",
        "system.task.build_module" => "notify_and_proceed",
        "system.task.commit_module" => "notify_and_proceed",
        "system.task.ssh_command" => "require_approval",      # arbitrary code execution
        "system.task.backup" => "auto_approve",
        "system.task.restore" => "require_approval",          # overwrites state
        "system.task.custom" => "require_approval"            # unknown semantics
      }.freeze

      # The row SHAPE these declarations resolve at. Load-bearing: an
      # agent-scoped row can never match an agent-less operator caller
      # (Ai::InterventionPolicy#agent_matches?), so the operator path needs a
      # row of exactly this shape or it falls through to the require_approval
      # default regardless of what any agent-scoped row says.
      MANUAL_OPERATION_SCOPE = { scope: "global", ai_agent_id: nil, user_id: nil }.freeze

      MANUAL_OPERATION_ATTRIBUTES = {
        priority: 5,
        is_active: true,
        conditions: {},
        preferred_channels: %w[notification]
      }.freeze
    end
  end
end
