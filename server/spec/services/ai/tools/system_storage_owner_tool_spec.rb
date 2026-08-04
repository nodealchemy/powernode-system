# frozen_string_literal: true

require "rails_helper"

# Audit F5-10 — full dispatch/permission/happy-path coverage for the
# StorageAssignment ownership MCP surface (previously this file only held the
# F8-02 permission-slug regression). Mirrors system_fleet_tool_spec.rb.
RSpec.describe Ai::Tools::SystemStorageOwnerTool do
  let(:account)  { create(:account) }
  let(:user)     { create(:user, account: account, permissions: described_class::ACTION_PERMISSIONS.values.uniq) }
  let(:tool)     { described_class.new(account: account, user: user) }

  let(:file_storage) { create(:file_storage, :nfs, :node_mountable, account: account) }
  let(:assignment) do
    create(:system_storage_assignment, account: account, file_storage_id: file_storage.id)
  end

  def call(action, **rest)
    tool.execute(params: { action: action }.merge(rest))
  end

  def other_account_assignment
    other = create(:account)
    fs = create(:file_storage, :nfs, :node_mountable, account: other)
    create(:system_storage_assignment, account: other, file_storage_id: fs.id, owner_kind: "root")
  end

  # F5-10 case 1 — dispatch table: every advertised action routes to a
  # handler (catches registry/handler drift via the "Unknown action" fall-through).
  describe "action dispatch table" do
    described_class::ACTION_PERMISSIONS.each_key do |action|
      it "routes #{action} to a handler" do
        result = begin
          call(action)
        rescue StandardError
          { success: false, error: "handler raised" }
        end
        expect(result[:error].to_s).not_to include("Unknown action")
      end
    end
  end

  # F5-10 case 2 — permission mapping enforced per action.
  describe "permission mapping" do
    described_class::ACTION_PERMISSIONS.each do |action, permission|
      it "permits #{action} for a holder of #{permission}" do
        holder = create(:user, account: account, permissions: [ permission ])
        scoped = described_class.new(account: account, user: holder)
        expect(scoped.send(:action_permitted?, action)).to be true
      end
    end

    it "denies a mutating action when the caller lacks its permission" do
      reader = create(:user, account: account, permissions: %w[system.storage.read])
      scoped = described_class.new(account: account, user: reader)
      r = scoped.execute(params: { action: "system_assign_storage_owner",
                                   storage_assignment_id: assignment.id, owner_kind: "root" })
      expect(r[:success]).to be false
      expect(r[:error]).to include("permission denied")
    end
  end

  # F5-10 case 3 — one happy path per action family + invalid params produce
  # a structured error, not an exception.
  describe "ownership lifecycle" do
    it "assigns an operator/root owner and returns a structured payload" do
      r = call("system_assign_storage_owner", storage_assignment_id: assignment.id, owner_kind: "root")
      expect(r[:success]).to be true
      expect(r[:data][:owner_kind]).to eq("root")
      expect(assignment.reload.owner_kind).to eq("root")
    end

    it "rejects an invalid owner_kind with a structured error" do
      r = call("system_assign_storage_owner", storage_assignment_id: assignment.id, owner_kind: "wizard")
      expect(r[:success]).to be false
      expect(r[:error]).to include("owner_kind must be one of")
    end

    it "requires service_user_username when owner_kind=service_user" do
      r = call("system_assign_storage_owner", storage_assignment_id: assignment.id, owner_kind: "service_user")
      expect(r[:success]).to be false
      expect(r[:error]).to include("service_user_username is required")
    end

    it "lists assignments filtered by owner_kind, account-scoped" do
      assignment.update!(owner_kind: "root")
      other_account_assignment # must not leak across accounts

      r = call("system_list_storage_assignments_by_owner", owner_kind: "root")
      expect(r[:success]).to be true
      expect(r[:data][:assignments].map { |a| a[:id] }).to contain_exactly(assignment.id)
    end

    it "reports chown status for an assignment" do
      r = call("system_storage_chown_status", storage_assignment_id: assignment.id)
      expect(r[:success]).to be true
      expect(r[:data][:storage_assignment_id]).to eq(assignment.id)
      expect(r[:data]).to have_key(:chown_state)
    end

    it "force-completes a chown as an operator escape hatch" do
      assignment.update_columns(chown_state: "failed", chown_last_error: "earlier failure")

      r = call("system_storage_chown_retry", storage_assignment_id: assignment.id, force_complete: true)
      expect(r[:success]).to be true
      expect(r[:data][:forced]).to be true
      expect(assignment.reload.chown_state).to eq("complete")
    end

    it "rejects chown retry from a non-retryable state" do
      assignment.update_columns(chown_state: "complete")

      r = call("system_storage_chown_retry", storage_assignment_id: assignment.id)
      expect(r[:success]).to be false
      expect(r[:error]).to include("retry is only valid")
    end

    it "returns a structured error for an unknown assignment id" do
      r = call("system_storage_chown_status", storage_assignment_id: SecureRandom.uuid)
      expect(r[:success]).to be false
      expect(r[:error]).to be_present
    end
  end

  # IMP-66ac8e46a6fb — assign_storage_owner/chown_status/chown_retry used a bare
  # ::System::StorageAssignment.find(params[:storage_assignment_id]) with no account
  # scope, so a caller holding system.storage.assignments.update in their OWN account
  # could reassign ownership (and dispatch a real chown task) onto ANOTHER account's
  # StorageAssignment. list_storage_assignments_by_owner already scoped correctly —
  # the sibling action that DOES scope is the tell.
  describe "cross-account IDOR guard (IMP-66ac8e46a6fb)" do
    it "does not let assign_storage_owner mutate another account's assignment" do
      foreign = other_account_assignment
      r = call("system_assign_storage_owner", storage_assignment_id: foreign.id, owner_kind: "operator")

      expect(r[:success]).to be false
      expect(foreign.reload.owner_kind).to eq("root")
    end

    it "does not let storage_chown_status read another account's assignment" do
      foreign = other_account_assignment
      r = call("system_storage_chown_status", storage_assignment_id: foreign.id)

      expect(r[:success]).to be false
    end

    it "does not let storage_chown_retry force-complete another account's assignment" do
      foreign = other_account_assignment
      foreign.update_columns(chown_state: "failed")
      r = call("system_storage_chown_retry", storage_assignment_id: foreign.id, force_complete: true)

      expect(r[:success]).to be false
      expect(foreign.reload.chown_state).to eq("failed")
    end
  end

  # F8-02 (retained): ACTION_PERMISSIONS mapped the mutating actions to
  # "system.storage.update", which has no Permission record, so non-super-admins
  # were permanently denied. Pin the grantable slugs.
  describe "delegation-action permission slugs (F8-02)" do
    let(:operator) { create(:user, account: account, permissions: %w[system.storage.assignments.update]) }
    let(:scoped)   { described_class.new(account: account, user: operator) }

    %w[system_assign_storage_owner system_storage_chown_retry].each do |action|
      it "permits #{action} for a holder of system.storage.assignments.update" do
        expect(scoped.send(:action_permitted?, action)).to be true
      end
    end
  end

  # IMP-54bf2643f542 — action_permitted? used to read `@user.nil?` as
  # "internal/system caller" and return true. That premise (MCP callers always
  # carry a user) predates instance principals: an mTLS node cert authenticates
  # with NO user, so every per-action permission here was skipped and the
  # peer's per-tool grant glob was the only remaining control. Sibling of the
  # SystemFleetTool fix (IMP-9030413bc292): the bypass is now two EXPLICIT
  # signals and a bare userless call fails closed.
  describe "principal authorization (IMP-54bf2643f542)" do
    let(:gated_action) { "system_assign_storage_owner" }

    it "denies a bare userless call — no user, no internal flag, no instance grant" do
      bare = described_class.new(account: account, user: nil)

      expect(bare.send(:action_permitted?, gated_action)).to be false
    end

    it "surfaces the denial as an error_result rather than executing the action" do
      bare = described_class.new(account: account, user: nil)

      expect {
        @result = bare.execute(params: { action: gated_action,
                                         storage_assignment_id: assignment.id, owner_kind: "root" })
      }.not_to change { assignment.reload.owner_kind }
      expect(@result[:success]).to be false
      expect(@result[:error]).to include("permission denied")
    end

    it "preserves the internal/system bypass when declared explicitly" do
      internal = described_class.new(account: account, user: nil, internal: true)

      expect(internal.send(:action_permitted?, gated_action)).to be true
    end

    # Behaviour preservation for the live instance principal: the streamable
    # controller grant-gates the specific tool name via Mcp::Principal#may_invoke?
    # before dispatch, and the registrar marks the call. That marking — not the
    # nil user — is what carries it through here.
    it "still permits a grant-gated MCP instance principal" do
      instance_call = described_class.new(account: account, user: nil)
      instance_call.instance_authorized = true

      expect(instance_call.send(:action_permitted?, gated_action)).to be true
    end

    it "keeps enforcing per-action permissions for a user principal" do
      reader = create(:user, account: account, permissions: %w[system.storage.read])
      user_tool = described_class.new(account: account, user: reader)

      expect(user_tool.send(:action_permitted?, "system_storage_chown_status")).to be true
      expect(user_tool.send(:action_permitted?, gated_action)).to be false
    end
  end
end
