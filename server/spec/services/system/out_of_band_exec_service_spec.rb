# frozen_string_literal: true

require "rails_helper"

# IMP-9ce0ed39c557 — the gated out-of-band exec primitive: refusal checks
# (self-node INV-1, self-hosting-unconfigured, unsafe IP, the IP pin, SSH
# disabled, operation authorization, the requester's own authorization
# re-checked at execution time), a fail-closed STARTED audit row, the
# bounded SSH call, a best-effort FINISHED audit row recording the outcome,
# and a best-effort REFUSED audit row for every refusal (security review
# finding S5).
RSpec.describe System::OutOfBandExecService do
  include PermissionTestHelpers

  let(:account)  { create(:account) }
  let(:node)     { create(:system_node, account: account) }
  let(:instance) { create(:system_node_instance, :running, node: node, account: account) }

  # A decoy self-hosting node, unrelated to `node`/`instance` and with NO
  # instances of its own — self_hosting_node_id must be CONFIGURED for
  # out-of-band-exec to run at all (security review finding S2), but this
  # keeps #self_hosting_addresses reduced to loopback-only, so it can never
  # accidentally collide with a factory-random instance IP under test.
  let(:self_hosting_node) { create(:system_node, account: create(:account)) }

  let(:ok_result) do
    ::System::Runtime::Result.ok(
      data: { stdout: "ok", stderr: "", exit_code: 0, timed_out: false, truncated: false }
    )
  end

  # The default requester for #approved_operation below — a genuine person
  # holding the permission the action runs under (review finding C2-4), so
  # every OTHER describe block in this file (none of which is testing C2-4
  # itself) keeps exercising the ordinary, authorized-requester path rather
  # than tripping the new re-check by accident.
  let(:requesting_user) { create(:user, account: account, permissions: %w[system.instances.control]) }

  # A real, approved, executing Ai::DeferredOperation — the shape #execute!
  # requires since security review finding S4 (defense in depth: it must be
  # backed by a decided, approved Ai::ApprovalRequest). Built through the
  # real AASM lifecycle, not update_columns, for the same reason the reaper
  # spec's start_executing helper is (see that file's header).
  #
  # `requested_by:` (C2-4) defaults to `requesting_user` and is threaded onto
  # BOTH the approval request and the operation — matching what
  # Ai::AutonomyGate actually does (create_approval_request! copies
  # deferred.requested_by onto the request it opens) — so a caller can
  # override just one half, or pass `requested_by: nil` on both, to build the
  # specific shapes the C2-4 describe block below exercises.
  def approved_operation(target_instance: instance, command: "uptime", requested_by: requesting_user,
                         **params_overrides)
    request = create(:ai_approval_request, :approved, account: account, requested_by: requested_by)
    op = ::Ai::DeferredOperation.create!(
      account: account,
      action_category: described_class::ACTION_CATEGORY,
      executor_class: "System::Executors::OutOfBandExec",
      approval_request: request,
      requested_by: requested_by,
      params: { instance_id: target_instance.id, command: command }.merge(params_overrides)
    )
    op.approve!
    op.start_execution!
    op.reload
  end

  # UNSET_PIN, not a plain `pinned_ip: nil` keyword default — review finding
  # R2-2 made a nil pin an execution-time refusal, so this helper must
  # supply a REAL pin by default (matching what the real gating surface
  # always resolves before parking) while still letting the dedicated
  # nil-pin test pass an EXPLICIT `pinned_ip: nil` through unchanged. A plain
  # `pinned_ip: nil` default here could not tell "caller didn't ask" from
  # "caller explicitly wants nil" apart.
  UNSET_PIN = Object.new.freeze

  def execute!(deferred_operation: nil, command: "uptime", pinned_ip: UNSET_PIN, **kw)
    resolved_pin = pinned_ip.equal?(UNSET_PIN) ? instance.ssh_ip_address : pinned_ip
    described_class.execute!(
      instance: instance, command: command, pinned_ip: resolved_pin,
      deferred_operation: deferred_operation || approved_operation(command: command), **kw
    )
  end

  before do
    allow(::System::SshExecutionService).to receive(:execute_bounded).and_return(ok_result)
    ::SiteSetting.set(
      ::System::Autonomy::SelfManagementFence::SELF_HOSTING_NODE_ID_KEY,
      self_hosting_node.id, setting_type: "string"
    )
  end

  describe "the ordinary case" do
    it "runs the bounded SSH call and returns success/exit_code/timed_out/truncated" do
      result = execute!

      expect(::System::SshExecutionService).to have_received(:execute_bounded).with(
        instance: instance, command: "uptime", sudo: true,
        timeout_seconds: described_class::DEFAULT_TIMEOUT_SECONDS,
        max_output_bytes: described_class::DEFAULT_MAX_OUTPUT_BYTES
      )
      expect(result[:success]).to be true
      expect(result[:exit_code]).to eq(0)
      expect(result[:timed_out]).to be false
      expect(result[:truncated]).to be false
      expect(result[:stdout]).to eq("ok")
      expect(result[:stderr]).to eq("")
    end

    it "reads timeout_seconds and max_output_bytes from SiteSetting when configured" do
      ::SiteSetting.set(described_class::TIMEOUT_SETTING_KEY, "45", setting_type: "integer")
      ::SiteSetting.set(described_class::MAX_OUTPUT_SETTING_KEY, "2048", setting_type: "integer")

      execute!

      expect(::System::SshExecutionService).to have_received(:execute_bounded).with(
        hash_including(timeout_seconds: 45, max_output_bytes: 2048)
      )
    end
  end

  describe "#refusal (read-only predicate)" do
    it "is nil for an ordinary target with no pin" do
      expect(described_class.new.refusal(instance: instance, command: "uptime")).to be_nil
    end

    it "refuses a blank command" do
      expect(described_class.new.refusal(instance: instance, command: "")).to match(/no command/i)
    end

    it "writes no audit row at all — it is a read-only preflight, nothing has been attempted" do
      described_class.new.refusal(instance: instance, command: "")
      expect(::AuditLog.where(resource_type: "System::NodeInstance", resource_id: instance.id.to_s)).to be_empty
    end
  end

  describe "the secret-shaped command refusal (security review, command-text decision)" do
    let(:secret_command) { "export PASSWORD=hunter2-secret-pw && restart-service" }

    it "refuses via #refusal without echoing the command" do
      message = described_class.new.refusal(instance: instance, command: secret_command)

      expect(message).to match(/secret-shaped/i)
      expect(message).not_to include("hunter2-secret-pw")
    end

    it "refuses via #execute!, audits the refusal, and never runs the command" do
      expect { execute!(command: secret_command, deferred_operation: approved_operation(command: secret_command)) }
        .to raise_error(described_class::Refused, /secret-shaped/i)

      expect(::System::SshExecutionService).not_to have_received(:execute_bounded)
      row = ::AuditLog.find_by!(resource_type: "System::NodeInstance", resource_id: instance.id.to_s,
                                 action: described_class::REFUSED_ACTION)
      expect(row.metadata["reason"]).to match(/secret-shaped/i)
      expect(row.metadata.to_s).not_to include("hunter2-secret-pw")
    end
  end

  describe "self-node refusal (INV-1)" do
    before do
      ::SiteSetting.set(
        ::System::Autonomy::SelfManagementFence::SELF_HOSTING_NODE_ID_KEY, node.id, setting_type: "string"
      )
    end

    it "refuses before ever calling SshExecutionService" do
      expect { execute! }.to raise_error(described_class::Refused, /INV-1|self-management/i)
      expect(::System::SshExecutionService).not_to have_received(:execute_bounded)
    end

    # Review finding S5 — this is an intentional BEHAVIOR CHANGE from the
    # pre-security-review version of this test (which asserted the opposite:
    # "writes no audit row at all"). Every refusal from #execute! is now
    # audited so a refused attempt is not invisible to an operator.
    it "writes a REFUSED audit row with the refusal reason" do
      expect { execute! }.to raise_error(described_class::Refused)

      row = ::AuditLog.find_by!(resource_type: "System::NodeInstance", resource_id: instance.id.to_s,
                                 action: described_class::REFUSED_ACTION)
      expect(row.metadata["reason"]).to match(/INV-1|self-management/i)
      # Review finding C2-8 — pin the exact key set, and confirm exactly ONE
      # REFUSED row (not zero, not a duplicate from a retried write).
      expect(row.metadata.keys).to match_array(%w[reason deferred_operation_id])
      expect(::AuditLog.where(resource_type: "System::NodeInstance", resource_id: instance.id.to_s,
                              action: described_class::REFUSED_ACTION).count).to eq(1)
    end

    it "leaves other nodes reachable" do
      other_node = create(:system_node, account: account)
      other_instance = create(:system_node_instance, :running, node: other_node, account: account,
                              private_ip_address: "10.0.9.9", public_ip_address: "203.0.114.9")
      other_op = approved_operation(target_instance: other_instance)

      result = described_class.execute!(instance: other_instance, command: "uptime",
                                  pinned_ip: other_instance.ssh_ip_address, deferred_operation: other_op)

      expect(result[:success]).to be true
    end
  end

  describe "self-hosting-unconfigured refusal (security review finding S2 — fails closed)" do
    # SiteSetting validates `value` present for a "string" setting (no
    # BLANK_ALLOWED_KEYS entry for this key, and it should not gain one just
    # to make "unset" settable through .set) — "never configured" is
    # simulated by there being NO ROW at all, which is also the real shape a
    # fresh/never-touched deployment is in. SiteSetting.get returns nil for a
    # missing key.
    before { ::SiteSetting.where(key: ::System::Autonomy::SelfManagementFence::SELF_HOSTING_NODE_ID_KEY).delete_all }

    it "refuses when self_hosting_node_id has never been configured" do
      message = described_class.new.refusal(instance: instance, command: "uptime")

      expect(message).to match(/self_hosting_node_id/i)
    end

    it "refuses via #execute! and audits the refusal" do
      expect { execute! }.to raise_error(described_class::Refused, /self_hosting_node_id/i)
      expect(::System::SshExecutionService).not_to have_received(:execute_bounded)

      row = ::AuditLog.find_by!(resource_type: "System::NodeInstance", resource_id: instance.id.to_s,
                                 action: described_class::REFUSED_ACTION)
      expect(row.metadata["reason"]).to match(/self_hosting_node_id/i)
    end
  end

  describe "unsafe target address refusal (security review finding S2)" do
    it "refuses a loopback SSH address" do
      instance.update_columns(private_ip_address: "127.0.0.1", vpn_ip_address: nil, public_ip_address: nil)

      message = described_class.new.refusal(instance: instance, command: "uptime")

      expect(message).to match(/loopback/i)
    end

    it "refuses a link-local SSH address" do
      instance.update_columns(private_ip_address: "169.254.1.1", vpn_ip_address: nil, public_ip_address: nil)

      message = described_class.new.refusal(instance: instance, command: "uptime")

      expect(message).to match(/link-local/i)
    end

    it "refuses an address that matches one of the self-hosting node's OTHER instances, " \
       "even when the target's own node_id differs (INV-1 alone would miss this)" do
      shared_address = "10.9.9.9"
      create(:system_node_instance, :running, node: self_hosting_node, account: self_hosting_node.account,
             private_ip_address: shared_address, public_ip_address: nil, vpn_ip_address: nil)
      instance.update_columns(private_ip_address: shared_address, vpn_ip_address: nil, public_ip_address: nil)
      expect(instance.node_id).not_to eq(self_hosting_node.id) # confirms INV-1's own node-id check would NOT catch this

      message = described_class.new.refusal(instance: instance, command: "uptime")

      expect(message).to match(/own addresses/i)
    end

    it "refuses via #execute! and audits the refusal, never calling SshExecutionService" do
      instance.update_columns(private_ip_address: "127.0.0.1", vpn_ip_address: nil, public_ip_address: nil)

      expect { execute! }.to raise_error(described_class::Refused, /unsafe/i)
      expect(::System::SshExecutionService).not_to have_received(:execute_bounded)

      row = ::AuditLog.find_by!(resource_type: "System::NodeInstance", resource_id: instance.id.to_s,
                                 action: described_class::REFUSED_ACTION)
      expect(row.metadata["reason"]).to match(/loopback/i)
    end

    # Review finding R2-1 — the previous version of this check only compared
    # loopback/link-local shapes and did exact STRING matches against known
    # addresses, which let every one of these through.
    it "refuses the IPv4 unspecified (\"any\") address 0.0.0.0" do
      instance.update_columns(private_ip_address: "0.0.0.0", vpn_ip_address: nil, public_ip_address: nil)

      message = described_class.new.refusal(instance: instance, command: "uptime")

      expect(message).to match(/unspecified/i)
    end

    it "refuses the IPv6 unspecified (\"any\") address ::" do
      instance.update_columns(private_ip_address: "::", vpn_ip_address: nil, public_ip_address: nil)

      message = described_class.new.refusal(instance: instance, command: "uptime")

      expect(message).to match(/unspecified/i)
    end

    it "refuses the IPv4 broadcast address 255.255.255.255" do
      instance.update_columns(private_ip_address: "255.255.255.255", vpn_ip_address: nil, public_ip_address: nil)

      message = described_class.new.refusal(instance: instance, command: "uptime")

      expect(message).to match(/broadcast/i)
    end

    it "refuses a multicast address" do
      instance.update_columns(private_ip_address: "224.0.0.5", vpn_ip_address: nil, public_ip_address: nil)

      message = described_class.new.refusal(instance: instance, command: "uptime")

      expect(message).to match(/multicast/i)
    end

    it "refuses an IPv4-mapped IPv6 form of a control-plane address (::ffff:<hub ip>)" do
      hub_address = "10.5.5.5"
      create(:system_node_instance, :running, node: self_hosting_node, account: self_hosting_node.account,
             private_ip_address: hub_address, public_ip_address: nil, vpn_ip_address: nil)
      instance.update_columns(private_ip_address: "::ffff:#{hub_address}", vpn_ip_address: nil, public_ip_address: nil)

      message = described_class.new.refusal(instance: instance, command: "uptime")

      expect(message).to match(/own addresses/i)
    end

    # Review finding C2-4-round-3 — the OLDER, deprecated "IPv4-compatible"
    # IPv6 form (::a.b.c.d, no "ffff:") is a DIFFERENT encoding from the
    # ipv4-mapped one above (IPAddr#ipv4_mapped? is false for it), so a fix
    # scoped to #ipv4_mapped? alone would miss this spelling of the same
    # address entirely.
    it "refuses an IPv4-compatible IPv6 form of a control-plane address (::<hub ip>, " \
       "the deprecated compat form, distinct from ::ffff:<hub ip>)" do
      hub_address = "10.5.5.6"
      create(:system_node_instance, :running, node: self_hosting_node, account: self_hosting_node.account,
             private_ip_address: hub_address, public_ip_address: nil, vpn_ip_address: nil)
      instance.update_columns(private_ip_address: "::#{hub_address}", vpn_ip_address: nil, public_ip_address: nil)

      message = described_class.new.refusal(instance: instance, command: "uptime")

      expect(message).to match(/own addresses/i)
    end

    it "refuses a non-canonical IPv6 spelling of a hub IPv6 address" do
      canonical = "2001:db8::1"
      create(:system_node_instance, :running, node: self_hosting_node, account: self_hosting_node.account,
             private_ip_address: canonical, public_ip_address: nil, vpn_ip_address: nil)
      non_canonical = "2001:0db8:0000:0000:0000:0000:0000:0001"
      instance.update_columns(private_ip_address: non_canonical, vpn_ip_address: nil, public_ip_address: nil)

      message = described_class.new.refusal(instance: instance, command: "uptime")

      expect(message).to match(/own addresses/i)
    end

    it "does not refuse a legitimate foreign IP that merely resembles nothing dangerous" do
      instance.update_columns(private_ip_address: "203.0.113.77", vpn_ip_address: nil, public_ip_address: nil)

      message = described_class.new.refusal(instance: instance, command: "uptime")

      expect(message).to be_nil
    end
  end

  describe "IP-pin refusal on repoint" do
    it "runs when the pinned IP still matches the instance's current SSH IP" do
      pinned = instance.ssh_ip_address

      result = execute!(pinned_ip: pinned)

      expect(result[:success]).to be true
      expect(::System::SshExecutionService).to have_received(:execute_bounded)
    end

    it "refuses when the instance's SSH IP no longer matches the pin, without calling SshExecutionService" do
      pinned = instance.ssh_ip_address
      instance.update_columns(private_ip_address: "10.0.0.250", vpn_ip_address: nil, public_ip_address: nil)
      expect(instance.reload.ssh_ip_address).not_to eq(pinned)

      expect { execute!(pinned_ip: pinned) }.to raise_error(described_class::Refused, /repoint|pinned/i)
      expect(::System::SshExecutionService).not_to have_received(:execute_bounded)
    end

    # Review finding R2-2 — this REPLACES the pre-round-2 version of this
    # test, which asserted the opposite ("pinning is opt-in per caller").
    # That was the actual bug the round-2 review challenged: a nil pin at
    # EXECUTION time is never legitimate (the gating surface always resolves
    # and supplies one when it parks), so skipping the repoint check rather
    # than refusing was the gap.
    it "refuses at execution time when pinned_ip is nil, rather than skipping the repoint check" do
      expect { execute!(pinned_ip: nil) }.to raise_error(described_class::Refused, /not approved/i)
      expect(::System::SshExecutionService).not_to have_received(:execute_bounded)
    end

    it "audits the nil-pin refusal" do
      expect { execute!(pinned_ip: nil) }.to raise_error(described_class::Refused)

      row = ::AuditLog.find_by!(resource_type: "System::NodeInstance", resource_id: instance.id.to_s,
                                 action: described_class::REFUSED_ACTION)
      expect(row.metadata["reason"]).to match(/no pinned_ip/i)
    end
  end

  describe "SSH-disabled refusal (security review finding S6)" do
    before do
      allow(::System::SshExecutionService).to receive(:ssh_enabled?).and_return(false)
    end

    it "refuses rather than letting a mocked run report success" do
      expect { execute! }.to raise_error(described_class::Refused, /ssh disabled/i)
      expect(::System::SshExecutionService).not_to have_received(:execute_bounded)
    end

    it "audits the refusal with a reason containing 'ssh disabled', never success: true" do
      expect { execute! }.to raise_error(described_class::Refused)

      row = ::AuditLog.find_by!(resource_type: "System::NodeInstance", resource_id: instance.id.to_s,
                                 action: described_class::REFUSED_ACTION)
      expect(row.metadata["reason"]).to match(/ssh disabled/i)
      expect(::AuditLog.where(resource_type: "System::NodeInstance", resource_id: instance.id.to_s,
                              action: described_class::FINISHED_ACTION)).to be_empty
    end
  end

  describe "operation-authorization refusal (security review finding S4 — defense in depth)" do
    it "refuses when no deferred_operation is supplied at all" do
      expect { described_class.execute!(instance: instance, command: "uptime", pinned_ip: instance.ssh_ip_address) }
        .to raise_error(described_class::Refused, /not approved/i)
      expect(::System::SshExecutionService).not_to have_received(:execute_bounded)
    end

    it "refuses when the operation is still pending (never approved)" do
      request = create(:ai_approval_request, :pending, account: account)
      op = ::Ai::DeferredOperation.create!(
        account: account, action_category: described_class::ACTION_CATEGORY,
        executor_class: "System::Executors::OutOfBandExec", approval_request: request,
        params: { instance_id: instance.id, command: "uptime" }
      )

      expect { execute!(deferred_operation: op) }.to raise_error(described_class::Refused, /not approved/i)
      expect(::System::SshExecutionService).not_to have_received(:execute_bounded)
    end

    it "refuses when the operation carries no approval_request at all" do
      op = ::Ai::DeferredOperation.create!(
        account: account, action_category: described_class::ACTION_CATEGORY,
        executor_class: "System::Executors::OutOfBandExec",
        params: { instance_id: instance.id, command: "uptime" }
      )
      op.approve!
      op.start_execution!

      expect { execute!(deferred_operation: op.reload) }.to raise_error(described_class::Refused, /not approved/i)
      expect(::System::SshExecutionService).not_to have_received(:execute_bounded)
    end

    it "audits the refusal" do
      expect { described_class.execute!(instance: instance, command: "uptime", pinned_ip: instance.ssh_ip_address) }
        .to raise_error(described_class::Refused)

      row = ::AuditLog.find_by!(resource_type: "System::NodeInstance", resource_id: instance.id.to_s,
                                 action: described_class::REFUSED_ACTION)
      expect(row.metadata["reason"]).to match(/not approved/i)
    end

    it "runs normally when backed by a real approved, executing operation" do
      result = execute!(deferred_operation: approved_operation)

      expect(result[:success]).to be true
      expect(::System::SshExecutionService).to have_received(:execute_bounded)
    end
  end

  describe "the requester's own authorization, re-checked at execution time (review finding C2-4)" do
    it "refuses when the requester's system.instances.control was revoked after park, " \
       "even though the operation itself is approved and executing" do
      op = approved_operation
      # The real park -> approve lifecycle already ran (in #approved_operation)
      # BEFORE the permission is revoked here — mirrors the real timeline: an
      # operator's approval, hours later, cannot re-authorize a requester who
      # has since lost the permission the action runs under.
      revoke_permissions(requesting_user, "system.instances.control")

      expect { execute!(deferred_operation: op) }
        .to raise_error(described_class::Refused, /no longer holds|permission revoked/i)
      expect(::System::SshExecutionService).not_to have_received(:execute_bounded)
    end

    it "audits the permission-revoked refusal with a static reason and no command text" do
      op = approved_operation(command: "uptime")
      revoke_permissions(requesting_user, "system.instances.control")

      expect { execute!(deferred_operation: op, command: "uptime") }.to raise_error(described_class::Refused)

      row = ::AuditLog.find_by!(resource_type: "System::NodeInstance", resource_id: instance.id.to_s,
                                 action: described_class::REFUSED_ACTION)
      expect(row.metadata["reason"]).to match(/no longer holds|permission revoked/i)
      expect(row.metadata.to_s).not_to include("uptime")
      # Same closed-key-set / exactly-one-row pattern every other REFUSED
      # assertion in this file pins (e.g. the self-node describe block above).
      expect(row.metadata.keys).to match_array(%w[reason deferred_operation_id])
      expect(::AuditLog.where(resource_type: "System::NodeInstance", resource_id: instance.id.to_s,
                              action: described_class::REFUSED_ACTION).count).to eq(1)
    end

    it "refuses when the requester cannot be resolved at all — no requester was recorded on " \
       "either the operation or its approval request" do
      op = approved_operation(requested_by: nil)

      expect { execute!(deferred_operation: op) }
        .to raise_error(described_class::Refused, /unresolvable/i)
      expect(::System::SshExecutionService).not_to have_received(:execute_bounded)
    end

    it "audits the unresolvable-requester refusal" do
      op = approved_operation(requested_by: nil)

      expect { execute!(deferred_operation: op) }.to raise_error(described_class::Refused)

      row = ::AuditLog.find_by!(resource_type: "System::NodeInstance", resource_id: instance.id.to_s,
                                 action: described_class::REFUSED_ACTION)
      expect(row.metadata["reason"]).to match(/unresolvable/i)
      expect(::AuditLog.where(resource_type: "System::NodeInstance", resource_id: instance.id.to_s,
                              action: described_class::REFUSED_ACTION).count).to eq(1)
    end

    it "still runs normally when the requester holds the permission (the ordinary path is " \
       "unaffected by this re-check)" do
      result = execute!(deferred_operation: approved_operation)

      expect(result[:success]).to be true
      expect(::System::SshExecutionService).to have_received(:execute_bounded)
    end
  end

  describe "the STARTED audit row (fail-closed)" do
    it "is written and DURABLY COMMITTED before the SSH call runs — with the fixture's own baseline of open transactions" do
      baseline = ActiveRecord.all_open_transactions.size
      open_txns_at_call = nil
      started_committed_at_call = nil

      allow(::System::SshExecutionService).to receive(:execute_bounded) do
        open_txns_at_call = ActiveRecord.all_open_transactions.size
        started_committed_at_call = ::AuditLog.exists?(
          resource_type: "System::NodeInstance", resource_id: instance.id.to_s,
          action: described_class::STARTED_ACTION
        )
        ok_result
      end

      execute!

      expect(open_txns_at_call).to eq(baseline)
      expect(started_committed_at_call).to be true
    end

    it "raises and never calls SshExecutionService when the started audit write fails" do
      allow(::AuditLog).to receive(:create!).and_call_original
      allow(::AuditLog).to receive(:create!)
        .with(hash_including(action: described_class::STARTED_ACTION))
        .and_raise(ActiveRecord::StatementInvalid, "connection lost")

      expect { execute! }.to raise_error(ActiveRecord::StatementInvalid)
      expect(::System::SshExecutionService).not_to have_received(:execute_bounded)
    end

    it "never logs the command text in the started audit metadata (crypto-safety)" do
      execute!

      row = ::AuditLog.find_by!(resource_type: "System::NodeInstance", resource_id: instance.id.to_s,
                                 action: described_class::STARTED_ACTION)
      expect(row.metadata.to_s).not_to include("uptime")

      # Review finding (#9): a substring check alone only catches a future
      # regression that happens to carry this exact command's text — a key
      # added as `command_preview:` or similar could slip through with a
      # DIFFERENT command's text and pass the check above by accident.
      # Asserting the exact, closed key set catches ANY new key here, command
      # text or not — #write_started_audit! must never gain one.
      #
      # deferred_operation_id is present now (security review finding S4 made
      # a real backing operation mandatory, so the default #execute! helper
      # always supplies one) — sudo and deferred_operation_id are the only
      # two keys #write_started_audit! ever populates without an explicit
      # agent_id/call_origin.
      expect(row.metadata.keys).to match_array(%w[sudo deferred_operation_id])
    end

    it "records agent_id, deferred_operation_id and call_origin when supplied" do
      op = approved_operation
      execute!(deferred_operation: op, agent_id: "agent-123", call_origin: "mcp_oauth")

      row = ::AuditLog.find_by!(resource_type: "System::NodeInstance", resource_id: instance.id.to_s,
                                 action: described_class::STARTED_ACTION)
      expect(row.metadata["agent_id"]).to eq("agent-123")
      expect(row.metadata["deferred_operation_id"]).to eq(op.id)
      expect(row.metadata["call_origin"]).to eq("mcp_oauth")
    end
  end

  describe "the FINISHED audit row (best-effort)" do
    it "records success, exit_code, timed_out and truncated" do
      allow(::System::SshExecutionService).to receive(:execute_bounded).and_return(
        ::System::Runtime::Result.err(
          error: "Command timed out",
          data: { stdout: "partial", stderr: "", exit_code: nil, timed_out: true, truncated: true }
        )
      )

      execute!

      row = ::AuditLog.find_by!(resource_type: "System::NodeInstance", resource_id: instance.id.to_s,
                                 action: described_class::FINISHED_ACTION)
      expect(row.metadata["success"]).to be false
      expect(row.metadata["timed_out"]).to be true
      expect(row.metadata["truncated"]).to be true
    end

    it "does not raise, and the command's own result still returns, when the finished audit write fails" do
      allow(::AuditLog).to receive(:create!).and_call_original
      allow(::AuditLog).to receive(:create!)
        .with(hash_including(action: described_class::FINISHED_ACTION))
        .and_raise(ActiveRecord::StatementInvalid, "connection lost")
      allow(Rails.logger).to receive(:error)

      result = nil
      expect { result = execute! }.not_to raise_error

      expect(result[:success]).to be true
      expect(Rails.logger).to have_received(:error).with(a_string_matching(/finished-audit/i))
    end

    it "never logs the command text in the finished audit metadata" do
      execute!

      row = ::AuditLog.find_by!(resource_type: "System::NodeInstance", resource_id: instance.id.to_s,
                                 action: described_class::FINISHED_ACTION)
      expect(row.metadata.to_s).not_to include("uptime")

      # Same closed-key-set strengthening as the STARTED row above, and the
      # same deferred_operation_id note.
      expect(row.metadata.keys).to match_array(%w[sudo success exit_code timed_out truncated deferred_operation_id])
    end
  end

  describe "the timeout_seconds ceiling (review finding #6)" do
    it "clamps a SiteSetting value above the hard maximum rather than honoring it unbounded" do
      ::SiteSetting.set(described_class::TIMEOUT_SETTING_KEY, "999999", setting_type: "integer")

      execute!

      expect(::System::SshExecutionService).to have_received(:execute_bounded).with(
        hash_including(timeout_seconds: described_class::MAX_TIMEOUT_SECONDS)
      )
    end

    it "leaves an in-range configured value untouched" do
      ::SiteSetting.set(described_class::TIMEOUT_SETTING_KEY, "60", setting_type: "integer")

      execute!

      expect(::System::SshExecutionService).to have_received(:execute_bounded).with(
        hash_including(timeout_seconds: 60)
      )
    end
  end

  describe "the max_output_bytes ceiling (review finding R2-3)" do
    it "clamps a SiteSetting value above the hard 1 MiB ceiling rather than honoring it unbounded" do
      ::SiteSetting.set(described_class::MAX_OUTPUT_SETTING_KEY, "999999999", setting_type: "integer")

      execute!

      expect(::System::SshExecutionService).to have_received(:execute_bounded).with(
        hash_including(max_output_bytes: described_class::MAX_OUTPUT_BYTES_CEILING)
      )
      expect(described_class::MAX_OUTPUT_BYTES_CEILING).to eq(1024 * 1024)
    end

    it "leaves an in-range configured value untouched" do
      ::SiteSetting.set(described_class::MAX_OUTPUT_SETTING_KEY, "2048", setting_type: "integer")

      execute!

      expect(::System::SshExecutionService).to have_received(:execute_bounded).with(
        hash_including(max_output_bytes: 2048)
      )
    end
  end

  describe "the returned diagnostic hash (review finding #8)" do
    it "includes stdout and stderr from the bounded SSH result" do
      allow(::System::SshExecutionService).to receive(:execute_bounded).and_return(
        ::System::Runtime::Result.ok(
          data: { stdout: "line one\nline two", stderr: "a warning", exit_code: 0,
                   timed_out: false, truncated: false }
        )
      )

      result = execute!

      expect(result[:stdout]).to eq("line one\nline two")
      expect(result[:stderr]).to eq("a warning")
    end
  end
end
