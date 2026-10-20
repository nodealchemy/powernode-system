# frozen_string_literal: true

require "rails_helper"

# IMP-5c6a03c3b335 (D4) - MCP surface for operator-issued enrolment keys
# (System::BootstrapToken, purpose operator_key):
#
#   system_list_bootstrap_tokens   read; metadata only, never a secret
#   system_revoke_bootstrap_token  approval-gated (system.bootstrap_token.revoke)
#   system_reveal_bootstrap_token  HUMAN-ONLY and approval-gated
#                                  (system.bootstrap_token.reveal); returns the
#                                  plaintext of an unconsumed, unrevoked,
#                                  unexpired key ONCE, to the approving person.
#
# There is no mint verb: key generation is REST-only (operator UI), server-side.
RSpec.describe Ai::Tools::SystemFleetTool, "operator enrolment keys" do
  let(:account) { create(:account) }
  let(:perms)   { %w[system.instances.control system.nodes.read system.node_instances.read ai.autonomy.approve] }
  let(:user)     { create(:user, account: account, permissions: perms) }
  let(:approver) { create(:user, account: account, permissions: perms) }
  let(:node)     { create(:system_node, account: account) }
  let(:instance) { create(:system_node_instance, node: node, account: account, status: "pending") }

  let(:reveal_category) { "system.bootstrap_token.reveal" }
  let(:revoke_category) { "system.bootstrap_token.revoke" }

  let!(:minted) do
    System::BootstrapToken.issue!(node: node, node_instance: instance, intended_subject: instance.id,
                                  purpose: "operator_key", created_by: user)
  end
  let(:token)     { minted.first }
  let(:plaintext) { minted.last }

  before { System::Governance::PolicyReconciler.new(account: account).reconcile! }

  def tool(u = user) = described_class.new(account: account, user: u)
  def workflow = Ai::Autonomy::ApprovalWorkflowService.new(account: account)

  def reveal!(t = tool, id: token.id)
    t.execute(params: { action: "system_reveal_bootstrap_token", token_id: id })
  end

  def revoke!(t = tool, id: token.id)
    t.execute(params: { action: "system_revoke_bootstrap_token", token_id: id })
  end

  def list!(t = tool, **rest)
    t.execute(params: { action: "system_list_bootstrap_tokens", instance_id: instance.id }.merge(rest))
  end

  def parked_after(response)
    expect(response[:data]).to include(pending: true), response.inspect
    Ai::DeferredOperation.find(response[:data][:deferred_operation_id])
  end

  def approve_in_own_session!(deferred, as: approver)
    request = deferred.approval_request
    expect(workflow.approve(request: request, approver: as, origin: Ai::ApprovalDecision::REST_SESSION)).to be(true)
    [ deferred.reload, request ]
  end

  def parked(category) = Ai::DeferredOperation.where(account: account, action_category: category)
  def revealed_audits = AuditLog.where(action: "system.bootstrap_token.revealed", resource_id: token.id)

  describe "the declarations" do
    it "declares list as a read, revoke as a gated destructive write, reveal as gated human-only" do
      list   = described_class.declared_action("system_list_bootstrap_tokens")
      revoke = described_class.declared_action("system_revoke_bootstrap_token")
      reveal = described_class.declared_action("system_reveal_bootstrap_token")

      expect(list).to include(mutating: false)
      expect(revoke).to include(mutating: true, destructive: true, action_category: revoke_category,
                                executor_class: "Ai::Executors::DeferredToolCall")
      expect(reveal).to include(mutating: true, destructive: true, human_only: true, action_category: reveal_category,
                                executor_class: "Ai::Executors::DeferredToolCall")
    end

    it "declares both categories require_approval, agent-less, scope global, and not reported as unowned" do
      declared = System::Governance::PolicyDeclarations::BOOTSTRAP_TOKEN_POLICIES
      expect(declared).to eq(reveal_category => "require_approval", revoke_category => "require_approval")
      [ reveal_category, revoke_category ].each do |category|
        expect(::Ai::InterventionPolicy.registered_categories).to include(category)
        expect(::Ai::InterventionPolicy.find_by(account: account, action_category: category))
          .to have_attributes(scope: "global", ai_agent_id: nil, policy: "require_approval")
      end
      subjects = ::System::Fleet::Sensors::GovernanceGapSensor.new(account: account).sense.map { |s| s.payload["subject"] }
      expect(subjects).not_to include(reveal_category, revoke_category)
    end

    it "maps all three verbs to system.instances.control and registers them in the tool catalog" do
      %w[system_list_bootstrap_tokens system_revoke_bootstrap_token system_reveal_bootstrap_token].each do |verb|
        expect(described_class::ACTION_PERMISSIONS[verb]).to eq("system.instances.control")
        expect(::Ai::Tools::PlatformApiToolRegistry.all_tools[verb]).to eq("Ai::Tools::SystemFleetTool")
        expect(described_class.action_definitions).to have_key(verb)
      end
    end

    it "offers no mint verb: key generation is server-side REST only" do
      expect(described_class.action_definitions.keys.grep(/bootstrap_token/))
        .to contain_exactly("system_list_bootstrap_tokens", "system_revoke_bootstrap_token",
                            "system_reveal_bootstrap_token")
    end
  end

  describe "system_list_bootstrap_tokens" do
    it "lists the instance's keys with no token, digest or sealed copy" do
      response = list!

      expect(response[:success]).to be(true), response.inspect
      rows = response[:data][:bootstrap_tokens]
      expect(response[:data]).to include(:count, :has_more)
      expect(rows.map { |r| r[:id] }).to eq([ token.id ])
      expect(rows.first.keys).to match_array(
        %i[id purpose node_instance_id expires_at consumed_at consumed_from_ip revoked_at created_by created_at]
      )
      expect(response.to_json).not_to include(plaintext)
      expect(response.to_json).not_to include(token.token_hash)
    end

    it "does not list another account's instance" do
      other = create(:account)
      other_instance = create(:system_node_instance, node: create(:system_node, account: other), account: other)
      response = list!(instance_id: other_instance.id)
      expect(response[:success]).to be(false)
    end

    it "is refused without system.instances.control" do
      reader = create(:user, account: account, permissions: %w[system.nodes.read])
      response = list!(tool(reader))
      expect(response[:success]).to be(false)
    end
  end

  describe "system_reveal_bootstrap_token" do
    it "parks a human-only approval and reveals nothing to the requester" do
      response = reveal!

      deferred = parked_after(response)
      expect(response[:data]).to include(requires_human_session: true)
      expect(response.to_json).not_to include(plaintext)
      expect(deferred.approval_request.requires_human_session?).to be(true)
      expect(deferred.description).to include(instance.name)
      expect(deferred.description).not_to include(plaintext)
      expect(revealed_audits).to be_empty
    end

    it "still parks under an auto_approve policy (human_only overrides it)" do
      allow_any_instance_of(::Ai::InterventionPolicyService).to receive(:resolve).and_return(
        { policy: "auto_approve", channels: [], conditions: {}, record: nil }
      )
      parked_after(reveal!)
      expect(revealed_audits).to be_empty
    end

    it "hands the plaintext to the APPROVING person once, audits them, and keeps it out of every durable copy" do
      deferred = parked_after(reveal!)

      deferred, request = approve_in_own_session!(deferred)

      revealed = request.take_revealed_result!
      expect(revealed.dig(:data, :token)).to eq(plaintext)
      expect(request.take_revealed_result!).to be_nil

      expect(deferred.status).to eq("completed")
      expect(deferred.result.to_json).not_to include(plaintext)
      expect(deferred.params.to_json).not_to include(plaintext)
      expect(request.reload.request_data.to_json).not_to include(plaintext)

      row = revealed_audits.sole
      expect(row.user_id).to eq(approver.id)
      expect(row.metadata.to_json).not_to include(plaintext)
      expect(row.metadata.to_json).not_to include(token.token_hash)
      # a reveal does not consume the key
      expect(token.reload).to be_usable
      expect(token.sealed_plaintext).to eq(plaintext)
    end

    it "never writes the plaintext to the Rails log during park, approval and replay" do
      io = StringIO.new
      original = Rails.logger
      Rails.logger = ActiveSupport::Logger.new(io)
      begin
        deferred = parked_after(reveal!)
        approve_in_own_session!(deferred)
      ensure
        Rails.logger = original
      end
      expect(io.string).not_to include(plaintext)
    end

    it "refuses and parks nothing for a consumed key" do
      token.consume!
      response = reveal!
      expect(response[:success]).to be(false)
      expect(response.to_json).not_to include(plaintext)
      expect(parked(reveal_category)).to be_empty
    end

    it "refuses and parks nothing for a revoked key" do
      token.revoke!(by: user)
      response = reveal!
      expect(response[:success]).to be(false)
      expect(parked(reveal_category)).to be_empty
    end

    it "refuses and parks nothing for an expired key" do
      token.update_columns(expires_at: 1.minute.ago)
      response = reveal!
      expect(response[:success]).to be(false)
      expect(parked(reveal_category)).to be_empty
    end

    it "refuses a key with no sealed copy (other purpose)" do
      seed, = System::BootstrapToken.issue!(node: node, node_instance: instance, intended_subject: instance.id,
                                            purpose: "cloud_seed")
      response = reveal!(id: seed.id)
      expect(response[:success]).to be(false)
      expect(parked(reveal_category)).to be_empty
    end

    it "treats another account's key as not found" do
      other = create(:account)
      other_node = create(:system_node, account: other)
      other_instance = create(:system_node_instance, node: other_node, account: other, status: "pending")
      foreign, = System::BootstrapToken.issue!(node: other_node, node_instance: other_instance,
                                               intended_subject: other_instance.id, purpose: "operator_key")
      response = reveal!(id: foreign.id)
      expect(response[:success]).to be(false)
      expect(parked(reveal_category)).to be_empty
    end

    it "is refused without system.instances.control" do
      nobody = create(:user, account: account, permissions: %w[system.nodes.read])
      response = reveal!(tool(nobody))
      expect(response[:success]).to be(false)
      expect(parked(reveal_category)).to be_empty
    end

    it "reveals nothing when the key is consumed while the request is parked" do
      deferred = parked_after(reveal!)
      token.consume!(from_ip: "203.0.113.7")

      deferred, request = approve_in_own_session!(deferred)

      expect(request.take_revealed_result!).to be_nil
      expect(deferred.result.to_json).not_to include(plaintext)
      expect(revealed_audits).to be_empty
    end

    it "reveals nothing when the key is revoked while the request is parked" do
      deferred = parked_after(reveal!)
      token.revoke!(by: user)

      _, request = approve_in_own_session!(deferred)

      expect(request.take_revealed_result!).to be_nil
      expect(revealed_audits).to be_empty
    end

    it "fails closed: no plaintext when the reveal audit row cannot be written" do
      deferred = parked_after(reveal!)
      allow(AuditLog).to receive(:log_action).and_raise(StandardError, "audit down")

      _, request = approve_in_own_session!(deferred)

      expect(request.take_revealed_result!).to be_nil
    end

    it "clears nothing and reveals nothing when approved with no person's decision" do
      deferred = parked_after(reveal!)
      deferred.approval_request.update_columns(status: "approved", completed_at: Time.current)
      deferred.execute_now!

      expect(deferred.take_revealed_result!).to be_nil
      expect(revealed_audits).to be_empty
    end
  end

  describe "system_revoke_bootstrap_token" do
    it "parks an approval and revokes nothing until it is decided" do
      deferred = parked_after(revoke!)

      expect(token.reload.revoked_at).to be_nil
      expect(token.sealed_plaintext).to eq(plaintext)
      expect(deferred.description).to include(instance.name)
    end

    it "revokes, purges the sealed copy and audits once approved" do
      deferred = parked_after(revoke!)

      approve_in_own_session!(deferred)

      token.reload
      expect(token.revoked_at).to be_present
      expect(token.sealed_plaintext).to be_nil
      expect(AuditLog.where(action: "system.bootstrap_token.revoked", resource_id: token.id).count).to eq(1)
    end

    it "refuses and parks nothing for an already-consumed key" do
      token.consume!
      response = revoke!
      expect(response[:success]).to be(false)
      expect(parked(revoke_category)).to be_empty
    end

    it "treats another account's key as not found" do
      other = create(:account)
      other_node = create(:system_node, account: other)
      foreign, = System::BootstrapToken.issue!(node: other_node, intended_subject: "x", purpose: "operator_key")
      response = revoke!(id: foreign.id)
      expect(response[:success]).to be(false)
      expect(foreign.reload.revoked_at).to be_nil
    end

    it "is refused without system.instances.control" do
      nobody = create(:user, account: account, permissions: %w[system.nodes.read])
      expect(revoke!(tool(nobody))[:success]).to be(false)
      expect(parked(revoke_category)).to be_empty
    end
  end
end
