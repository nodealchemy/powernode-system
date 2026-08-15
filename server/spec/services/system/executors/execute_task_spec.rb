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

  # IMP-a449bc347e94 — the approval card for a gated task dispatch.
  #
  # Both gate call sites nest the row attributes under :task_attributes
  # (tasks_controller#create and NodeInstanceGating's gate_or_execute /
  # gate_ip_action), but summarize read params[:command] and impact read
  # params[:operable_type]/[:operable_id] at the TOP level — so every deferred
  # task's card read "Execute system task: " with impact " on system", naming
  # neither the command nor the target the approver is deciding about.
  #
  # These examples drive the ACTUAL preview a gated request produces: the gate
  # stores the caller's params shape on the DeferredOperation row, and the card
  # renders from a FRESH load of that row (JSONB round-trip — string keys), not
  # from a hand-built symbol-keyed hash.
  describe "the approval card for a gated request" do
    let(:user) { create(:user, account: account) }

    # Mirrors tasks_controller#create verbatim — nesting, source anchors,
    # description. NodeInstanceGating's gate_or_execute/gate_ip_action dispatch
    # the identical :task_attributes nesting.
    def gated_card(attrs)
      result = ::Ai::AutonomyGate.evaluate(
        action_category: "system.task.#{attrs[:command]}",
        executor_class: described_class.name,
        params: { task_attributes: attrs },
        account: account,
        requested_by: user,
        source_type: attrs[:operable_type].presence,
        source_id: attrs[:operable_id].presence,
        description: "#{attrs[:command]} on #{attrs[:operable_type]}##{attrs[:operable_id]}".strip
      )
      operation = result.deferred_operation
      expect(operation).to be_present,
                           "gate returned no deferred operation (decision=#{result.decision}, error=#{result.error})"
      ::Ai::DeferredOperation.find(operation.id).preview
    end

    it "names the command on the summary line" do
      node.update!(name: "edge-lon-01")
      card = gated_card(command: "sync", operable_type: "System::Node",
                        operable_id: node.id, initiated_by_id: user.id)

      expect(card[:summary]).to eq("Execute system task: sync")
    end

    it "names the command and the operable's name on the impact line" do
      node.update!(name: "edge-lon-01")
      card = gated_card(command: "sync", operable_type: "System::Node",
                        operable_id: node.id, initiated_by_id: user.id)

      expect(card[:impact]).to eq("sync on System::Node edge-lon-01")
    end

    # The lifecycle dispatch shape — an operable with no account_id column of
    # its own (NodeInstance's account flows through node), so the name lookup
    # cannot depend on a uniform account_id.
    it "names the instance for a NodeInstanceGating lifecycle dispatch" do
      instance = create(:system_node_instance, account: account, name: "web-1")
      card = gated_card(command: "stop", operable_type: "System::NodeInstance",
                        operable_id: instance.id, initiated_by_id: user.id)

      expect(card[:impact]).to eq("stop on System::NodeInstance web-1")
    end

    it "reads 'on system' when no operable is named, but still names the command" do
      card = gated_card(command: "sync", initiated_by_id: user.id)

      expect(card[:summary]).to eq("Execute system task: sync")
      expect(card[:impact]).to eq("sync on system")
    end

    # A preview must render, never refuse — but it must not constantize its way
    # to a name either. A type outside OPERABLE_TYPES degrades to the caller's
    # own bare pair (perform refuses the same pair later, at execution).
    it "degrades an unallowlisted operable type to the caller's bare pair" do
      card = gated_card(command: "sync", operable_type: "Kernel", operable_id: account.id)

      expect(card[:impact]).to eq("sync on Kernel##{account.id}")
      expect(card[:error]).to be_nil
    end

    it "falls back to the bare pair when the operable row is gone" do
      missing = SecureRandom.uuid
      card = gated_card(command: "sync", operable_type: "System::Node", operable_id: missing)

      expect(card[:impact]).to eq("sync on System::Node##{missing}")
    end

    # Positive twin for the fallback rung: a flat direct-caller shape keeps a
    # working card, so supporting the controllers' nesting cannot have cost the
    # shape perform already accepted.
    it "still names the command and operable for a flat direct-caller params shape" do
      node.update!(name: "edge-lon-01")
      card = described_class.preview(
        { command: "sync", operable_type: "System::Node", operable_id: node.id,
          initiated_by_id: user.id }
      )

      expect(card[:summary]).to eq("Execute system task: sync")
      expect(card[:impact]).to eq("sync on System::Node edge-lon-01")
    end

    # What the card may DISCLOSE. These previews carry no operation (the
    # PRE-GATE shape — IMP-4a5094b22df0 threads one through for every card
    # composed via Ai::DeferredOperation#preview, but `preview(params)` alone
    # still has none), so resolve_scoped has no account anchor and passes any
    # existing row through — an unguarded name lookup would hand a caller-
    # supplied foreign UUID's name to the card at REQUEST time, before any
    # approval. The only trusted anchor there is the initiator both HTTP
    # gate surfaces force into task_attrs after permit (tasks_controller
    # merges current_user.id over the permitted keys; NodeInstanceGating
    # writes it directly).
    context "when the caller names a record it does not own as the operable" do
      it "does not disclose the foreign record's name on the card" do
        foreign_node.update!(name: "victim-payroll-node")
        card = gated_card(command: "sync", operable_type: "System::Node",
                          operable_id: foreign_node.id, initiated_by_id: user.id)

        expect(card[:impact]).not_to include("victim-payroll-node"),
                                     "the approval card leaked another account's record name: #{card[:impact].inspect}"
        expect(card[:impact]).to eq("sync on System::Node##{foreign_node.id}")
      end

      # The negation twin of the disclosure check: naming OWN records while
      # bare-pairing foreign ones must not let the caller distinguish "exists
      # elsewhere" from "exists nowhere" — the two cards must be identical up
      # to the id the caller themselves supplied.
      it "renders a foreign id exactly as it renders a missing id" do
        missing_id = SecureRandom.uuid
        foreign = gated_card(command: "sync", operable_type: "System::Node",
                             operable_id: foreign_node.id, initiated_by_id: user.id)
        missing = gated_card(command: "sync", operable_type: "System::Node",
                             operable_id: missing_id, initiated_by_id: user.id)

        expect(foreign[:impact].sub(foreign_node.id, "<id>"))
          .to eq(missing[:impact].sub(missing_id, "<id>")),
              "the card distinguishes a foreign id from a missing one: " \
              "#{foreign[:impact].inspect} vs #{missing[:impact].inspect}"
      end

      # Without an initiator there is no anchor at all, so the card must not
      # name anything — a direct caller that wants names on its cards passes
      # the initiator, as both HTTP surfaces already do.
      it "falls back to the bare pair for a flat shape with no initiator" do
        node.update!(name: "edge-lon-01")
        card = described_class.preview(
          { command: "sync", operable_type: "System::Node", operable_id: node.id }
        )

        expect(card[:impact]).to eq("sync on System::Node##{node.id}")
      end
    end
  end
end
