# frozen_string_literal: true

require "rails_helper"

# `restart` is the lifecycle verb whose unit-scoped reading reaches the node
# agent's LifecycleHandler (agent/internal/runtime/tasks/handlers/lifecycle.go),
# which takes options["unit"] into `systemctl restart` as root. The in-process
# producer (System::RestartAfterUpdate#enqueue_restart!) calls
# System::Task.create! and never meets the gate, so this default governs ONLY
# the gate sites — TasksController#create, reached by any principal holding
# system.infra_tasks.create, including an AI agent (the system.task.* rows are
# seeded with ai_agent_id nil and Ai::InterventionPolicy#agent_matches? admits
# that). Those are exactly the callers whose payload is not vetted, and an
# auto_approve there ran a caller-chosen unit name through a root service
# manager with no human in the loop — while the storage verbs, whose payloads
# ARE validated at the agent, sat behind require_approval.
#
# WHAT THIS DEFAULT DOES **NOT** DO — read before assuming a live install is
# covered. These examples pin the DECLARATION, which is what a first boot seeds
# and what PolicyReconciler creates when the row is ABSENT. PolicyReconciler
# reconciles absence only ("Never update an existing row's verb" —
# policy_reconciler.rb:35-38) and `db:seed` is first-boot only
# (policy_declarations.rb:8-13), so an install whose database already holds a
# `system.task.restart` row — every established one, ops-hub included, seeded
# when the declared verb was auto_approve — KEEPS auto_approve after this ships.
# Widening the reconciler to rewrite it is the destructive behaviour its header
# forbids; the operator action is to retune that one row in System Settings →
# Manual Operations. The agent-side refusal (validateUnit in
# handlers/lifecycle.go) is the half that ships unconditionally.
RSpec.describe System::Governance::PolicyDeclarations, "lifecycle verb defaults" do
  it "declares the unit-scoped restart verb as require_approval" do
    expect(described_class::MANUAL_OPERATION_DEFAULT_VERBS.fetch("restart")).to eq("require_approval")
  end

  it "resolves system.task.restart to require_approval in the seeded policy set" do
    expect(described_class::MANUAL_OPERATION_POLICIES.fetch("system.task.restart")).to eq("require_approval")
  end
end
