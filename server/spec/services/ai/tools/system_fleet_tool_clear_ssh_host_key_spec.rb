# frozen_string_literal: true

require "rails_helper"

# IMP-a41ceb3cdd64 — system_clear_ssh_host_key: the human-only, audited way to clear ONE
# instance's recorded SSH host key. After IMP-190834701b0a a recorded key makes every platform
# SSH path strict and out-of-band exec requires one; a node whose key changed and whose agent
# never heartbeats again is then locked out of its own break-glass diagnostic, and the only
# recovery was a console call to System::SshHostKeyWriter.clear!.
#
# Human-only: a tool call is never a person's consent, so the verb parks an approval under its
# own category and clear! runs only when a person approves in their own session, with THAT
# person as the audited actor. CLEAR ONLY — there is deliberately no pin verb: host key
# material does not travel through tool arguments.
RSpec.describe Ai::Tools::SystemFleetTool, "system_clear_ssh_host_key" do
  let(:account) { create(:account) }
  let(:user) do
    create(:user, account: account, permissions: %w[system.instances.control system.nodes.read ai.autonomy.approve])
  end
  # The person who decides is NOT the requester, so the audit actor can only be the approver.
  let(:approver) do
    create(:user, account: account, permissions: %w[system.instances.control system.nodes.read ai.autonomy.approve])
  end
  let(:node)     { create(:system_node, account: account) }
  let(:instance) { create(:system_node_instance, :running, node: node, account: account) }
  let(:ed25519)  { SshHostKeyFixtures.entry("ssh-ed25519") }
  let(:category) { "system.instance.ssh_host_key_clear" }

  before do
    System::Governance::PolicyReconciler.new(account: account).reconcile!
    System::SshHostKeyWriter.write!(instance: instance, payload: [ ed25519 ], boot_id: "boot-1")
  end

  def tool(u = user)
    described_class.new(account: account, user: u)
  end

  def clear!(t = tool, **rest)
    t.execute(params: { action: "system_clear_ssh_host_key", instance_id: instance.id,
                        reason: "reprovisioned, /persist was destroyed" }.merge(rest))
  end

  def recorded
    instance.reload.ssh_host_keys
  end

  def parked
    Ai::DeferredOperation.where(account: account, action_category: category)
  end

  def cleared_audits
    AuditLog.where(action: System::SshHostKeyWriter::CLEARED_ACTION, resource_id: instance.id.to_s)
  end

  def workflow = Ai::Autonomy::ApprovalWorkflowService.new(account: account)

  def parked_after(response)
    expect(response[:data]).to include(pending: true, requires_human_session: true), response.inspect
    Ai::DeferredOperation.find(response[:data][:deferred_operation_id])
  end

  def approve_in_own_session!(deferred, as: user)
    expect(workflow.approve(request: deferred.approval_request, approver: as,
                            origin: Ai::ApprovalDecision::REST_SESSION)).to be(true)
    deferred.reload
  end

  def expect_refused(response, message)
    expect(response[:success]).to be(false)
    expect(response[:error]).to match(message)
    expect(parked).to be_empty
    expect(recorded).not_to be_nil
    expect(cleared_audits).to be_empty
  end

  describe "the declaration" do
    let(:declaration) { described_class.declared_action("system_clear_ssh_host_key") }

    it "is mutating, destructive and human-only, gated under its own require_approval category" do
      expect(declaration).to include(mutating: true, destructive: true, human_only: true,
                                     action_category: category, executor_class: "Ai::Executors::DeferredToolCall")
      expect(System::Governance::PolicyDeclarations::SSH_HOST_KEY_CLEAR_POLICIES).to eq(category => "require_approval")
      expect(System::Governance::PolicyDeclarations.owner_of(category)).to be_nil
    end

    it "is registered for the Autonomy panel, reconciled agent-less at scope global, and not reported as unowned" do
      expect(::Ai::InterventionPolicy.registered_categories).to include(category)
      expect(::Ai::InterventionPolicy.find_by(account: account, action_category: category))
        .to have_attributes(scope: "global", ai_agent_id: nil, policy: "require_approval")
      subjects = ::System::Fleet::Sensors::GovernanceGapSensor.new(account: account).sense.map { |s| s.payload["subject"] }
      expect(subjects).not_to include(category)
    end

    it "takes system.instances.control, is in the tool catalog, and requires instance_id and reason" do
      expect(described_class::ACTION_PERMISSIONS["system_clear_ssh_host_key"]).to eq("system.instances.control")
      expect(::Ai::Tools::PlatformApiToolRegistry.all_tools["system_clear_ssh_host_key"]).to eq("Ai::Tools::SystemFleetTool")
      params = described_class.action_definitions.fetch("system_clear_ssh_host_key")[:parameters]
      expect(params.slice(:instance_id, :reason).values.map { |p| p[:required] }).to all(be(true))
      expect(params.keys).to contain_exactly(:instance_id, :reason)
    end

    it "offers no way to PIN a key: no key material parameter" do
      names = described_class.action_definitions.keys.grep(/ssh_host_key/)

      expect(names).to eq([ "system_clear_ssh_host_key" ])
    end
  end

  describe "the gate" do
    it "parks a human-only approval, clears nothing, and names the instance and reason on the card" do
      deferred = parked_after(clear!)

      expect(recorded).not_to be_nil
      expect(cleared_audits).to be_empty
      expect(deferred.approval_request.requires_human_session?).to be(true)
      expect(deferred.description).to include(instance.name).and include("reprovisioned")
    end

    it "still parks under an auto_approve policy (human_only overrides it)" do
      allow_any_instance_of(::Ai::InterventionPolicyService).to receive(:resolve).and_return(
        { policy: "auto_approve", channels: [], conditions: {}, record: nil }
      )

      parked_after(clear!)
      expect(recorded).not_to be_nil
    end

    it "clears the key and writes the audit row naming the APPROVING person and the reason, when a person approves" do
      deferred = parked_after(clear!)

      approve_in_own_session!(deferred, as: approver)

      expect(recorded).to be_nil
      row = cleared_audits.sole
      expect(row.user_id).to eq(approver.id)
      expect(row.user_id).not_to eq(user.id)
      expect(row.metadata["reason"]).to eq("reprovisioned, /persist was destroyed")
      expect(row.metadata["previous_fingerprints"]).to eq([ SshHostKeyFixtures.fingerprint(ed25519["key"]) ])
      expect(row.metadata.to_json).not_to include(ed25519["key"])
    end

    it "shows the approver the fingerprints of the key being cleared, and records them as the park-time expectation" do
      fingerprint = SshHostKeyFixtures.fingerprint(ed25519["key"])
      deferred = parked_after(clear!)

      expect(deferred.description).to include(fingerprint).and include("Requester-supplied reason")
      expect(deferred.params.dig("tool_params", "expected_fingerprints")).to eq([ fingerprint ])
    end

    # expected_fingerprints is the platform's own stamp, so it is not a declared
    # parameter: with strict parameters a caller cannot supply one at all, and the
    # gate still mints the value itself (the example above).
    it "refuses a caller-supplied expected_fingerprints as an unrecognized parameter and parks nothing" do
      response = clear!(expected_fingerprints: [ "SHA256:attacker" ])

      expect(response[:success]).to be false
      expect(response[:error]).to include("Unrecognized parameter(s)").and include("expected_fingerprints")
      expect(Ai::DeferredOperation.count).to eq(0)
    end

    it "refuses on approval, and keeps the key, when the node re-recorded a DIFFERENT key while the request was parked" do
      deferred = parked_after(clear!)
      new_key = SshHostKeyFixtures.entry("ssh-ed25519", body_bytes: 48)
      instance.update_columns(ssh_host_keys: nil)
      System::SshHostKeyWriter.write!(instance: instance.reload, payload: [ new_key ], boot_id: "boot-2")

      approve_in_own_session!(deferred, as: approver)

      expect(recorded).not_to be_nil
      expect(cleared_audits).to be_empty
      expect(deferred.result.to_s).to match(/no longer the one this clear was requested for/)
    end

    it "clears nothing the second time when the same approval is replayed after a successful clear" do
      deferred = parked_after(clear!)
      approve_in_own_session!(deferred, as: approver)
      expect(cleared_audits.count).to eq(1)

      expect do
        System::SshHostKeyWriter.clear!(instance: instance, actor: approver, reason: "again",
                                        expect_fingerprints: [ SshHostKeyFixtures.fingerprint(ed25519["key"]) ])
      end.to raise_error(ArgumentError, /no longer the one/)
      expect(cleared_audits.count).to eq(1)
    end

    it "clears nothing when the request is approved with no person's decision" do
      deferred = parked_after(clear!)
      deferred.approval_request.update_columns(status: "approved", completed_at: Time.current)
      deferred.execute_now!

      expect(recorded).not_to be_nil
      expect(cleared_audits).to be_empty
    end
  end

  describe "the reply says what the next connection will do" do
    def reply_after_approval
      deferred = parked_after(clear!)
      approve_in_own_session!(deferred)
      deferred.result.to_s
    end

    it "with system.ssh.require_host_key OFF: legacy callers connect unverified, out-of-band exec is refused" do
      ::SiteSetting.set(System::SshExecutionService::REQUIRE_HOST_KEY_SETTING, "false", setting_type: "boolean")

      text = reply_after_approval

      expect(text).to match(/require_host_key.{0,20}(false|off)/i)
      expect(text).to match(/unverified/i)
      expect(text).to match(/out-of-band/i)
    end

    it "with system.ssh.require_host_key ON: legacy callers are refused, out-of-band exec is refused" do
      ::SiteSetting.set(System::SshExecutionService::REQUIRE_HOST_KEY_SETTING, "true", setting_type: "boolean")

      text = reply_after_approval

      expect(text).to match(/require_host_key is on: SSH and SCP to .* are REFUSED/i)
      expect(text).not_to match(/UNVERIFIED/)
      expect(text).to match(/out-of-band/i)
    end
  end

  describe "refusals before parking" do
    it "requires a reason, and refuses a blank or oversized one" do
      expect_refused(clear!(reason: nil), /reason/i)
      expect_refused(clear!(reason: "   "), /reason/i)
      expect_refused(clear!(reason: "x" * 1000), /reason/i)
    end

    it "refuses an unknown instance, and another account's" do
      expect_refused(clear!(instance_id: SecureRandom.uuid), /Couldn't find System::NodeInstance/)
      other = create(:system_node_instance, :running, node: create(:system_node, account: create(:account)))
      expect_refused(clear!(instance_id: other.id), /Couldn't find System::NodeInstance/)
    end

    it "refuses a reason carrying control characters, line separators or a bidi override" do
      [ "stale\nkey verified by security", "stale\e[31m", "stale\u202Eevil", "stale\u2028x" ].each do |reason|
        expect_refused(clear!(reason: reason), /control or bidirectional/)
      end
    end

    it "refuses an instance on a legacy shared mTLS identity: its heartbeat would never record a new key" do
      instance.update_columns(mtls_subject: "legacy-shared-hostname")

      expect_refused(clear!, /shared legacy mTLS identity/)
    end

    it "refuses an instance with no recorded key, since there is nothing to clear" do
      instance.update_columns(ssh_host_keys: nil)

      response = clear!

      expect(response[:success]).to be(false)
      expect(response[:error]).to match(/no recorded SSH host key/i)
      expect(parked).to be_empty
    end
  end

  describe "an instance principal" do
    def instance_tool
      described_class.new(account: account, user: nil).tap do |x|
        x.instance_authorized = true
        x.node_instance = instance
      end
    end

    it "is denied by the overlay, whatever it has granted itself" do
      expect(::Mcp::Principal.destructive_tool?("platform.system_clear_ssh_host_key")).to be true
      expect(::Mcp::Principal.destructive_tool?("system_clear_ssh_host_key")).to be true
    end

    it "is refused at the door before any gate work" do
      expect { clear!(instance_tool) }.to raise_error(Mcp::ProtocolService::PermissionDeniedError, /destroy-shaped/)
      expect(parked).to be_empty
      expect(recorded).not_to be_nil
    end

    it "is refused by the gate context and the arm themselves, independent of the overlay" do
      params = { action: "system_clear_ssh_host_key", instance_id: instance.id, reason: "stale" }
      t = instance_tool

      expect { t.send(:clear_ssh_host_key_gate_context, params) }
        .to raise_error(Ai::Tools::BaseTool::CallerFacingError, /instance principal/)
      expect(t.send(:clear_ssh_host_key, params)).to include(success: false)
      expect(recorded).not_to be_nil
    end
  end

  describe "a bare #call, or an approved replay no person confirmed" do
    it "is gate-routed only and clears nothing" do
      result = tool.send(:call, { action: "system_clear_ssh_host_key", instance_id: instance.id, reason: "stale" })

      expect(result[:success]).to be(false)
      expect(recorded).not_to be_nil
    end

    it "does not clear for an AGENT acting for the confirming person, even on a genuinely confirmed approval" do
      deferred = parked_after(clear!)
      approve_in_own_session!(deferred, as: approver)
      # The approval ran and cleared the key; put a key back so only the guard can stop a second clear.
      System::SshHostKeyWriter.write!(instance: instance.reload, payload: [ ed25519 ], boot_id: "boot-3")
      agent = create(:ai_agent, account: account, creator: approver, provider: create(:ai_provider, account: account))
      t = described_class.new(account: account, user: approver, agent: agent)
      t.replaying_operation = deferred.reload

      result = t.send(:call, { action: "system_clear_ssh_host_key", instance_id: instance.id, reason: "stale",
                               expected_fingerprints: [ SshHostKeyFixtures.fingerprint(ed25519["key"]) ] })

      expect(result[:success]).to be(false)
      expect(result[:error]).to match(/approval-gated and must be invoked via/)
      expect(recorded).not_to be_nil
    end

    it "does not clear for an internal caller either" do
      deferred = parked_after(clear!)
      approve_in_own_session!(deferred, as: approver)
      System::SshHostKeyWriter.write!(instance: instance.reload, payload: [ ed25519 ], boot_id: "boot-3")
      t = described_class.new(account: account, user: approver, internal: true)
      t.replaying_operation = deferred.reload

      result = t.send(:call, { action: "system_clear_ssh_host_key", instance_id: instance.id, reason: "stale",
                               expected_fingerprints: [ SshHostKeyFixtures.fingerprint(ed25519["key"]) ] })

      expect(result[:success]).to be(false)
      expect(recorded).not_to be_nil
    end
  end
end
