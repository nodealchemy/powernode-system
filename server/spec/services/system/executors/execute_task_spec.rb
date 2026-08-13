# frozen_string_literal: true

require "rails_helper"

# IMP-973670faeba9 — System::Task's operable is an OPEN polymorphic
# association (`belongs_to :operable, polymorphic: true, optional: true`), open
# in BOTH dimensions: any account's row, and any model at all.
#
# ExecuteTask sliced caller-supplied operable_type/operable_id straight into
# System::Task.new. Ai::AutonomyGate stores those params verbatim and replays
# them at approval time with no re-validation, and the task's account is set
# from the operation — so a caller could name another account's node and have
# the task execute against it while the audit row reads as a clean in-account
# operation. Live path: POST /api/v1/system/tasks.
#
# Both dimensions are pinned here, and they are independent defenses:
# System::Task::OPERABLE_TYPES decides WHAT may serve as an operable,
# resolve_scoped decides WHOSE row it may be. Neither subsumes the other —
# Account carries no account_id, so resolve_scoped alone would pass it through.
RSpec.describe System::Executors::ExecuteTask do
  let(:account)         { create(:account) }
  let(:foreign_account) { create(:account) }

  let(:node)         { create(:system_node, account: account) }
  let(:foreign_node) { create(:system_node, account: foreign_account) }

  def operation_for(owner)
    ::Ai::DeferredOperation.create!(
      account: owner, action_category: "system.task.sync",
      executor_class: described_class.name, params: {}
    )
  end

  # The executor is always reached through the gate's replay, which hands it
  # the operation — so every example drives the real entry point.
  def execute(owner: account, **task_attributes)
    described_class.execute({ task_attributes: task_attributes },
                            deferred_operation: operation_for(owner))
  end

  def refusal_from(**task_attributes)
    execute(**task_attributes)
    nil
  rescue StandardError => e
    e
  end

  describe "an operable the operation's account owns" do
    it "creates the task and attaches the resolved record" do
      result = execute(command: "sync", operable_type: "System::Node", operable_id: node.id)

      task = ::System::Task.find(result[:data][:task_id])
      expect(task.operable).to eq(node)
      expect(task.account_id).to eq(account.id)
    end

    it "still creates a task that names no operable at all" do
      result = execute(command: "sync")

      expect(::System::Task.find(result[:data][:task_id]).operable).to be_nil
    end
  end

  describe "an operable belonging to another account" do
    # Effect first: an example whose first assertion is the raise cannot report
    # the planted row it exists to prevent — it aborts on "nothing was raised"
    # while the foreign record sits attached.
    it "plants no task against the foreign record" do
      error = refusal_from(command: "sync", operable_type: "System::Node", operable_id: foreign_node.id)

      planted = ::System::Task.where(operable_type: "System::Node", operable_id: foreign_node.id)
      expect(planted.count).to eq(0),
                               "account #{account.id} attached another account's node to its own task: " \
                               "#{planted.map { |t| "#{t.id}(account #{t.account_id})" }.inspect}"
      expect(error).to be_a(::Ai::DeferredOperation::CrossAccountError)
    end

    # Ai::AutonomyGate rescues StandardError and returns error: e.message, which
    # the controller renders straight to the caller — so naming the owner turns
    # a cross-tenant probe into a working ownership oracle.
    it "refuses without naming the owning account" do
      error = refusal_from(command: "sync", operable_type: "System::Node", operable_id: foreign_node.id)

      expect(error).to be_a(::Ai::DeferredOperation::CrossAccountError)
      expect(error.message).not_to include(foreign_account.id),
                                   "the refusal echoes the victim's account id back to the caller"
    end
  end

  describe "a model that is not a task operable at all" do
    # Account is in-account by construction and carries no account_id, so
    # resolve_scoped would pass it straight through: the allowlist is the only
    # thing that can refuse this.
    it "refuses a type outside System::Task::OPERABLE_TYPES" do
      error = refusal_from(command: "sync", operable_type: "Account", operable_id: account.id)

      planted = ::System::Task.where(operable_type: "Account")
      expect(planted.count).to eq(0),
                               "an arbitrary model was attached as a task operable: #{planted.map(&:id).inspect}"
      expect(error).to be_a(::System::Task::BadOperableType)
    end

    it "names only the rejected type, never a constantized class" do
      error = refusal_from(command: "sync", operable_type: "Kernel", operable_id: account.id)

      expect(error).to be_a(::System::Task::BadOperableType)
      expect(::System::Task.where(operable_type: "Kernel").count).to eq(0)
    end

    # A refused TYPE is not a cross-tenant event: keeping them distinguishable
    # stops a malformed request from firing a tenancy alert. Subclassing is what
    # lets existing rescues and log greps keep working regardless.
    it "stays rescuable as a CrossAccountError for existing handlers" do
      error = refusal_from(command: "sync", operable_type: "Account", operable_id: account.id)

      expect(error).to be_a(::Ai::DeferredOperation::CrossAccountError)
    end
  end

  # What the caller may learn from a refusal, as opposed to what it prevents.
  describe "what the refusals disclose" do
    # Neither message names an owner, but the PAIR would still be an oracle: a
    # caller who can tell "exists elsewhere" from "exists nowhere" learns THAT a
    # row exists. The two refusals must be identical up to the id the caller
    # themselves supplied.
    it "refuses an id that exists nowhere exactly as it refuses a foreign one" do
      missing_id = SecureRandom.uuid
      missing = refusal_from(command: "sync", operable_type: "System::Node", operable_id: missing_id)
      foreign = refusal_from(command: "sync", operable_type: "System::Node", operable_id: foreign_node.id)

      expect(missing).to be_a(::Ai::DeferredOperation::CrossAccountError)
      expect(missing.class).to eq(foreign.class),
                               "a missing id and a foreign id raise different classes — a caller can tell them apart"
      expect(missing.message.sub(missing_id, "<id>"))
        .to eq(foreign.message.sub(foreign_node.id, "<id>")),
            "the two refusals differ by more than the caller's own id: #{missing.message.inspect} vs #{foreign.message.inspect}"
    end

    it "does not report a cross-account refusal as a bad-type refusal" do
      error = refusal_from(command: "sync", operable_type: "System::Node", operable_id: foreign_node.id)

      expect(error).not_to be_a(::System::Task::BadOperableType)
    end
  end
end
