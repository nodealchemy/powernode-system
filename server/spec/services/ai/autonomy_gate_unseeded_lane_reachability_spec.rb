# frozen_string_literal: true

require "rails_helper"

# IMP-c16864f5a1cd — PINS current behaviour before any remediation. Do not
# read a green run here as approval of the shape; it exists to answer one
# question the operator asked first: does a missing Ai::InterventionPolicy
# row on a real, currently-gated call site let the action RUN (fail open), or
# does it park for approval (fail closed)?
#
# Six call sites were named as driving Ai::AutonomyGate directly (none of
# them a System::Fleet::DecisionEngine / FleetAutonomyService-routed lane):
# Api::V1::System::DiskImagePublicationsController#rollback,
# Api::V1::System::TasksController#create, Sdwan::PeersController#destroy,
# System::NodeInstanceGating#gate_or_execute (x2), Ai::Tools::SdwanTool. This
# spec drives ONE of them — Sdwan::Executors::DeletePeer, reached from
# PeersController#destroy and from SdwanTool — end to end through the real
# Ai::AutonomyGate.evaluate, on an account that has never run
# System::Governance::PolicyReconciler (the `create(:account)` factory does
# not seed policy rows — confirmed by grepping the factory and Account model
# for any auto-reconcile callback: there is none), so the resolve genuinely
# hits Ai::InterventionPolicyService#default_policy's "no matching row" arm
# rather than a seeded one.
#
# THE MECHANISM THIS PINS, READ FROM THE CURRENT CODE:
#   Ai::InterventionPolicyService#default_policy (no matching row) => policy:
#   "require_approval", record: nil.
#   Ai::AutonomyGate#evaluate dispatches "require_approval" to
#   #require_approval_or_proceed, which branches on
#   `defined?(::Ai::ApprovalChain)`. That constant is a CORE model
#   (server/app/models/ai/approval_chain.rb) with no conditional
#   autoload/eager_load exclusion anywhere in config — core mode
#   (Shared::FeatureGateService.core_mode? == no extension ENGINES loaded)
#   never removes a core file, so the constant is defined on every
#   deployment, core mode or not. The method's own preceding comment already
#   says as much ("the chain models are CORE now, so `defined?` is always
#   true and every deployment parks here... do not read it as a live
#   core-mode mode"). This spec is the independent, executed check on that
#   claim, on a REAL six-call-site category rather than on the module in
#   isolation.
RSpec.describe "Ai::AutonomyGate — unseeded policy row on a directly-gated call site (IMP-c16864f5a1cd)" do
  let(:peer) { create(:sdwan_peer, :hub) }
  let(:account) { peer.account }

  it "is a category with no seeded policy row on this account" do
    expect(
      ::Ai::InterventionPolicy.active.where(account: account, action_category: "sdwan.peer_delete")
    ).to be_empty
  end

  it "resolves the missing row to require_approval, not silently to auto_approve" do
    policy_match = ::Ai::InterventionPolicyService.new(account: account).resolve(
      action_category: "sdwan.peer_delete", agent: nil, user: nil, environment: nil, blast_radius: nil
    )

    expect(policy_match[:policy]).to eq("require_approval")
    expect(policy_match[:record]).to be_nil
  end

  it "PARKS the action — decision :pending, ApprovalRequest created, peer NOT destroyed" do
    expect_any_instance_of(::Sdwan::Executors::DeletePeer).not_to receive(:perform)

    result = ::Ai::AutonomyGate.evaluate(
      action_category: ::Sdwan::Executors::DeletePeer::ACTION_CATEGORY,
      executor_class: "Sdwan::Executors::DeletePeer",
      params: { peer_id: peer.id },
      account: account,
      requested_by: nil,
      source_type: "Sdwan::Peer",
      source_id: peer.id,
      description: "Delete SDWAN peer #{peer.id}"
    )

    expect(result.decision).to eq(:pending)
    expect(result.proceed?).to be(false)
    expect(result.approval_request).to be_present
    expect(result.approval_request).to be_a(::Ai::ApprovalRequest)
    expect(::Sdwan::Peer.find_by(id: peer.id)).to be_present
  end

  it "does not require Ai::ApprovalChain to be undefined to reach the require_approval branch" do
    expect(defined?(::Ai::ApprovalChain)).to be_truthy
  end
end
