# frozen_string_literal: true

require "ipaddr"

module System
  # IMP-9ce0ed39c557 — the governed out-of-band exec primitive: runs ONE
  # command on a node over SSH, from the control plane, without the node's
  # own agent. Gated by the system.instance.out_of_band_exec approval
  # category (System::Governance::PolicyDeclarations), never a reuse of
  # system.task.ssh_command — auto-approving in-band SSH tasks must not
  # auto-approve this.
  #
  # Refusals are checked BEFORE anything runs or is audited. Two groups:
  #
  #   REQUEST-TIME + EXECUTION-TIME (both via #refusal — a gate_context
  #   preflight calls it before ever parking, #execute! calls it again right
  #   before running):
  #     * a blank or secret-shaped command (the approver sees the command
  #       text — see the class-level note below — so a command that would
  #       itself leak a credential must never even be parked).
  #     * INV-1 (System::Autonomy::SelfManagementFence) — never run a command
  #       on this control plane's own hosting node.
  #     * self_hosting_node_id UNCONFIGURED — FAILS CLOSED (security review
  #       finding S2). SelfManagementFence itself is inert-by-default when
  #       unset (correct for every OTHER consumer: "unknown" reasonably means
  #       "not self-hosted, e.g. a dev workstation"), but out-of-band-exec
  #       runs arbitrary root commands over SSH — for THIS verb specifically,
  #       "we cannot tell whether this is our own node" must refuse, not
  #       silently allow, until an operator configures the setting.
  #     * an unsafe target address — loopback, link-local, or one of this
  #       control plane's own addresses (the self-hosting node's instances'
  #       IPs). A second, IP-VALUE-keyed check independent of
  #       #self_managed_target?'s node-id-keyed one: a target's declared
  #       node_id could be stale or wrong while its actual address still
  #       resolves onto the self-hosting node.
  #     * NO RECORDED SSH HOST KEY (IMP-190834701b0a). The IP pin below
  #       proves the DB record was not repointed. It says nothing about WHICH
  #       host answers at that address, and VMID/IP reuse is routine. With no
  #       recorded key, SshExecutionService cannot verify the host, so this
  #       refuses before anything is parked (#execute_bounded refuses the
  #       same case again, as a backstop).
  #     * the IP PIN — the gating surface resolves and stores the instance's
  #       SSH IP into the parked operation at approval-REQUEST time
  #       (`pinned_ip:`); this re-checks it against the instance's CURRENT SSH
  #       IP at execution time (immediate, or hours later on approval), so a
  #       target repointed after a human approved the command is refused
  #       rather than silently retargeted.
  #
  #   EXECUTION-TIME ONLY (#execute! — meaningless before an operation
  #   exists / is decided):
  #     * SSH disabled (SYSTEM_SSH_ENABLED=false) — security review finding
  #       S6. #execute_bounded's own mock fallback exists so the ~40 other
  #       in-process #execute callers can run in a test env with no real SSH;
  #       for out-of-band-exec specifically, that convenience would let a
  #       mocked "it worked" get audited as if a real command ran, which is
  #       actively misleading for a feature whose entire point is delivering
  #       proof a specific command ran. Refused instead of silently mocked.
  #     * DEFENSE IN DEPTH (S4) — the operation this call runs for must
  #       itself be approved/executing and backed by a DECIDED, APPROVED
  #       Ai::ApprovalRequest. Catches a hypothetical direct call to this
  #       service that bypassed Ai::AutonomyGate entirely.
  #     * THE REQUESTER'S OWN AUTHORIZATION, RE-CHECKED (C2-4) — S4 asks
  #       whether the operation is approved; this asks whether the principal
  #       that originally REQUESTED it may still be trusted to have, now, at
  #       execution time. Every other human_only action replays through
  #       Ai::Executors::DeferredToolCall, which re-authorizes its confirming
  #       approver before it runs; this action's executor_class is this
  #       service's own executor (System::Executors::OutOfBandExec), never
  #       DeferredToolCall, so that generic re-check never fires for it.
  #       Without this, a requester whose system.instances.control was
  #       revoked between park and approval still gets their command run, on
  #       the strength of a decision made about a request that was
  #       authorized only at the moment it was filed. See
  #       #requester_authorization_refusal.
  #
  # EVERY refusal from #execute! is audited (security review finding S5) —
  # REFUSED_ACTION, metadata carries the refusal reason and never the command
  # text. #refusal alone (the pre-park preflight) writes nothing: it is
  # documented as a read-only predicate and nothing has been attempted yet.
  #
  # COMMAND TEXT (security review, command-text decision): kept, deliberately
  # — stored in the parked operation's params and shown to the approver, who
  # must see what they are being asked to authorize. It is never logged (see
  # SshExecutionService#execute_bounded's own header) and never written to
  # either AuditLog row here. The one guard on it is the secret-shaped check
  # above: a command that ITSELF carries inline secret-shaped material is
  # refused before ever reaching an approver, and that refusal message never
  # echoes the command (so refusing it does not leak it into an error either).
  #
  # Audit is FAIL-CLOSED on the way in and best-effort on the way out for a
  # run that actually starts: the STARTED row must be durably written before
  # the command runs (a write failure raises and the command never executes
  # — this is deliberately the one place in this class that does not
  # rescue), and the FINISHED row is rescued and logged rather than raised,
  # because by the time it is written the command has already run and
  # refusing now would only hide that it did. A REFUSED row (new) is also
  # best-effort: the refusal itself is what matters and must never be
  # swallowed by a broken audit write, so #write_refused_audit! rescues
  # internally and #execute! still raises Refused regardless.
  class OutOfBandExecService
    include ::System::Autonomy::SelfManagementFence

    class Refused < StandardError; end

    # The single source of truth for the category name — read by
    # PolicyDeclarations (the governance row), the gated executor, and
    # System::OutOfBandExecReaperService (which queries DeferredOperation by
    # it), so all three can never drift onto different strings.
    ACTION_CATEGORY = "system.instance.out_of_band_exec"

    # The permission the ORIGINAL REQUESTER must still hold at execution time
    # (C2-4, review finding). Same literal both doors gate the action's
    # decoration on (Ai::Tools::SystemFleetTool's ACTION_PERMISSIONS,
    # NodeInstancesController#out_of_band_exec) — kept as its own constant
    # here, not read from either, so this class does not need to know either
    # door's internals to re-ask the same question they already asked once.
    REQUESTER_PERMISSION = "system.instances.control"

    # Both are SiteSettings, registered via Ai::Tools::SiteSettingTool
    # (lib/powernode_system/engine.rb) — never hardcoded, per the brief.
    # Both are coerced to Integer by SiteSetting.get(setting_type: "integer")
    # before use, so an operator cannot smuggle shell-interpreted content
    # through either one even though neither is meant to hold any: they are
    # bounds, not commands, and never secrets.
    TIMEOUT_SETTING_KEY    = "system.out_of_band_exec.timeout_seconds"
    MAX_OUTPUT_SETTING_KEY = "system.out_of_band_exec.max_output_bytes"
    DEFAULT_TIMEOUT_SECONDS  = 120
    DEFAULT_MAX_OUTPUT_BYTES = 64 * 1024 # 64 KiB

    # Review finding: an operator-tunable SiteSetting with no ceiling lets a
    # single (mis)configured value turn every out-of-band command into a
    # multi-hour hold on a live node — an unbounded timeout_seconds is
    # effectively "no bound" again, defeating the whole point of this being a
    # BOUNDED runner. Clamped, not refused: a misconfigured huge value should
    # degrade to the platform's own ceiling rather than break the feature
    # outright for every caller until an operator notices and fixes it.
    MAX_TIMEOUT_SECONDS = 300

    # Review finding R2-3 — the SAME reasoning as MAX_TIMEOUT_SECONDS applies
    # to output: an unbounded max_output_bytes SiteSetting value is
    # effectively "no cap" again, and BoundedCommandRunner buffers output in
    # memory per stream for the life of the call.
    MAX_OUTPUT_BYTES_CEILING = 1024 * 1024 # 1 MiB

    # Fully-qualified audit-action tokens, registered into
    # AuditActions.all_actions by the system engine initializer (mirrors
    # System::InternalCaService::AUDITED_ACTIONS).
    STARTED_ACTION  = "system.out_of_band_exec.started"
    FINISHED_ACTION = "system.out_of_band_exec.finished"
    REFUSED_ACTION  = "system.out_of_band_exec.refused"
    AUDITED_ACTIONS = [ STARTED_ACTION, FINISHED_ACTION, REFUSED_ACTION ].freeze

    # Public, class-level (review finding C2-2) — the ONE place
    # timeout_seconds is read and clamped. OutOfBandExecReaperService cannot
    # call the private INSTANCE method below, so it used to duplicate the
    # read-and-clamp logic; a duplicate silently missed the MAX_TIMEOUT_SECONDS
    # clamp entirely for a full round. Shared here instead so the two can
    # never drift apart again.
    def self.configured_timeout_seconds
      value = ::SiteSetting.get(TIMEOUT_SETTING_KEY).to_i
      value = value.positive? ? value : DEFAULT_TIMEOUT_SECONDS
      [ value, MAX_TIMEOUT_SECONDS ].min
    end

    def self.execute!(instance:, command:, sudo: true, pinned_ip: nil, agent_id: nil,
                       deferred_operation: nil, call_origin: nil)
      new.execute!(instance: instance, command: command, sudo: sudo, pinned_ip: pinned_ip,
                   agent_id: agent_id, deferred_operation: deferred_operation,
                   call_origin: call_origin)
    end

    # `deferred_operation:` is the REAL Ai::DeferredOperation object (review
    # finding S4) — not merely its id. Ai::DeferredOperation#execute_now!
    # always calls the executor with `deferred_operation: self`
    # (post-start_execution!, so status is already "executing"), so this is
    # the same object the gate created; a direct call (bypassing the gate
    # entirely) supplies nil or something else, which #execute! now refuses.
    def execute!(instance:, command:, sudo: true, pinned_ip: nil, agent_id: nil,
                 deferred_operation: nil, call_origin: nil)
      refusal_message = refusal(instance: instance, command: command, pinned_ip: pinned_ip)
      # Execution-time only (review finding R2-2) — NOT folded into #refusal,
      # which the request-time gate_context preflight also calls with
      # pinned_ip always nil (the pin does not exist until parking succeeds).
      # Requiring a pin there would refuse every legitimate park. At
      # execution time a nil pin is never legitimate: the gating surface
      # always resolves and supplies one when it parks
      # (`pinned_ip: instance.ssh_ip_address`), so its absence here means
      # either a bypass of the normal gate or a stale pre-pin operation
      # shape — refuse rather than silently skip the repoint check #refusal
      # would otherwise run.
      refusal_message ||= nil_pin_refusal if pinned_ip.blank?
      refusal_message ||= ssh_disabled_refusal if ssh_disabled?
      refusal_message ||= unauthorized_operation_refusal(deferred_operation)
      refusal_message ||= requester_authorization_refusal(deferred_operation)

      if refusal_message
        write_refused_audit!(instance: instance, reason: refusal_message, agent_id: agent_id,
                              deferred_operation_id: deferred_operation&.id, call_origin: call_origin)
        raise Refused, refusal_message
      end

      # NOT rescued — see class header. A write failure here must abort the
      # whole call before SshExecutionService is ever reached.
      write_started_audit!(instance: instance, sudo: sudo, agent_id: agent_id,
                            deferred_operation_id: deferred_operation&.id, call_origin: call_origin)

      result = ::System::SshExecutionService.execute_bounded(
        instance: instance, command: command, sudo: sudo,
        timeout_seconds: timeout_seconds, max_output_bytes: max_output_bytes
      )

      write_finished_audit(instance: instance, sudo: sudo, result: result, agent_id: agent_id,
                            deferred_operation_id: deferred_operation&.id, call_origin: call_origin)

      {
        success: result.success?,
        exit_code: result.data[:exit_code],
        timed_out: !!result.data[:timed_out],
        truncated: !!result.data[:truncated],
        # Review finding, corrected C2-6: the diagnostic surface's whole point
        # is letting the requester see what ran — SshExecutionService
        # #build_bounded_result already redacts both (team-lead's explicit
        # call: return it redacted, since diagnosis is the point). This is
        # NOT a one-time return value that vanishes after this call returns —
        # Ai::DeferredOperation#execute_now! persists whatever this hash
        # returns into DeferredOperation#result (through
        # Ai::SensitiveParams.filter), so the redacted stdout/stderr ARE
        # durably stored there, readable on the operation after the fact.
        # Never added to either AuditLog row above, though — the audit
        # trail's own "never logs the command or output" guarantee is a
        # stricter promise than DeferredOperation#result's.
        stdout: result.data[:stdout],
        stderr: result.data[:stderr]
      }
    end

    # Read-only predicate — nil means "would proceed". Split out from
    # #execute! so a gate-context preflight (declared on the MCP tool) can
    # answer "would this be refused" without writing an audit row or running
    # anything, the same shape the pre-ruling reference implementation used.
    # Also re-checked by #execute! itself at execution time — see the class
    # header for why request-time and execution-time both matter here.
    def refusal(instance:, command:, pinned_ip: nil)
      return "no command given" if command.blank?
      return secret_shaped_command_refusal if ::System::ShellOutputSanitizer.secret_shaped?(command)
      return self_managed_refusal(instance) if self_managed_target?(instance)
      return self_hosting_unconfigured_refusal if self_hosting_node_id.blank?
      return unsafe_ip_refusal(instance) if unsafe_ip?(instance.ssh_ip_address)
      return no_host_key_refusal(instance) if ::System::SshHostKeys.recorded_for(instance).empty?
      return ip_pin_refusal(instance, pinned_ip) if pinned_ip.present? && instance.ssh_ip_address != pinned_ip

      nil
    end

    private

    # Never echoes the command (security review, command-text decision) —
    # the whole point of this refusal is that the command carries something
    # that must not travel further, so the error itself must not become a
    # second place it leaks to.
    def secret_shaped_command_refusal
      "refusing to run an out-of-band command — it appears to contain inline secret-shaped " \
        "material (a password, token, key or similar). The command text is not echoed here. " \
        "Remove the inline secret and re-submit; out-of-band-exec commands are shown verbatim " \
        "to the approver and must never carry one."
    end

    def self_managed_refusal(instance)
      "refusing to run an out-of-band command on instance #{instance.id} — it is this control " \
        "plane's own hosting node (INV-1: no self-management). Management authority must come " \
        "from the consensus group, never the node itself."
    end

    def self_hosting_unconfigured_refusal
      "refusing to run an out-of-band command — this deployment has not configured " \
        "#{::System::Autonomy::SelfManagementFence::SELF_HOSTING_NODE_ID_KEY} " \
        "(System::Autonomy::SelfManagementFence), so out-of-band-exec cannot verify a target is " \
        "not the control plane's own hosting node. An operator must set that SiteSetting before " \
        "this feature can run (fail closed, unlike the fence's own inert-by-default for other uses)."
    end

    def unsafe_ip_refusal(instance)
      address = instance.ssh_ip_address
      "refusing to run an out-of-band command on instance #{instance.id} — its SSH address " \
        "(#{address.inspect}) is unsafe: #{unsafe_ip_reason(address)}. Out-of-band-exec must " \
        "never target the control plane itself or an unaddressable target."
    end

    # Unspecified ("any" / "listen on everything") addresses — not caught by
    # #loopback?/#link_local? at all, and `ssh 0.0.0.0` or `ssh ::` resolves
    # to the LOCAL host on most stacks (review finding R2-1).
    UNSPECIFIED_V4 = ::IPAddr.new("0.0.0.0")
    UNSPECIFIED_V6 = ::IPAddr.new("::")
    # The IPv4 limited-broadcast address. (IPv6 has no broadcast concept —
    # ff00::/8 below is multicast, which is the closest analog and is
    # checked separately.)
    BROADCAST_V4 = ::IPAddr.new("255.255.255.255")
    MULTICAST_V4 = ::IPAddr.new("224.0.0.0/4")
    MULTICAST_V6 = ::IPAddr.new("ff00::/8")

    def unsafe_ip_reason(address)
      return "no usable SSH address is available" if address.blank?

      ip = parse_ip(address)
      return "the address is not a valid IP" if ip.nil?
      return "it is a loopback address" if ip.loopback?
      return "it is a link-local address" if ip.link_local?
      return "it is an unspecified (\"any\") address" if unspecified?(ip)
      return "it is a broadcast address" if ip == BROADCAST_V4
      return "it is a multicast address" if MULTICAST_V4.include?(ip) || MULTICAST_V6.include?(ip)

      "it matches one of this control plane's own addresses"
    end

    def unsafe_ip?(address)
      return true if address.blank?

      ip = parse_ip(address)
      return true if ip.nil?
      return true if ip.loopback? || ip.link_local? || unspecified?(ip)
      return true if ip == BROADCAST_V4
      return true if MULTICAST_V4.include?(ip) || MULTICAST_V6.include?(ip)

      # PARSED comparison (review finding R2-1), never a string one: an
      # IPv4-mapped (::ffff:<hub ip>) or IPv4-compatible (::<hub ip>) IPv6
      # form of a control-plane address, or a non-canonical IPv6 spelling of
      # one, would be a DIFFERENT string from what's stored but the SAME
      # address once parsed — #parse_ip normalizes both embedded-IPv4 forms
      # to their embedded IPv4 address, and IPAddr#== compares the numeric
      # address + family, not the spelling.
      self_hosting_addresses.any? { |own| own == ip }
    end

    def unspecified?(ip)
      ip == UNSPECIFIED_V4 || ip == UNSPECIFIED_V6
    end

    # Normalizes an IPv4-mapped (::ffff:a.b.c.d) OR IPv4-COMPATIBLE
    # (::a.b.c.d — the older, deprecated form; still parseable, and
    # `IPAddr#ipv4_compat?` warns rather than raises) IPv6 address to its
    # embedded IPv4 form (review finding R2-1, extended C2-4-round-3) —
    # otherwise either spelling would compare unequal to the plain "a.b.c.d"
    # a control-plane instance actually stores, letting that spelling of the
    # SAME address walk straight past the own-addresses check below.
    # `IPAddr#native` already checks BOTH forms internally (via its own
    # private `_ipv4_compat?`, not the public, warning-emitting
    # `#ipv4_compat?`) and returns `self` unchanged for neither, so calling
    # it unconditionally covers both without this method needing to branch
    # on which form it got, or trigger the obsolescence warning itself.
    def parse_ip(address)
      ::IPAddr.new(address).native
    rescue ::IPAddr::Error, ::ArgumentError
      nil
    end

    # This control plane's own reachable addresses, PARSED (review finding
    # R2-1 — compared as IPAddr objects everywhere above, never as strings):
    # loopback, plus every real IP any instance on the self-hosting node
    # advertises, plus the node's own host-level address when it records one
    # (System::Node#public_address — "public hostname or IP"; a hostname
    # fails #parse_ip and is silently dropped by compact, not a crash). Only
    # reached once self_hosting_node_id is known present (#refusal refuses
    # before this if it is blank), so the node lookup below always has an id
    # to look for — it may still miss (a stale/deleted System::Node id), in
    # which case this degrades to loopback-only.
    def self_hosting_addresses
      return @self_hosting_addresses if defined?(@self_hosting_addresses)

      raw = [ "127.0.0.1", "::1" ]
      node = ::System::Node.find_by(id: self_hosting_node_id)
      if node
        raw << node.public_address
        node.node_instances.find_each do |inst|
          raw.concat([ inst.vpn_ip_address, inst.private_ip_address, inst.public_ip_address ])
        end
      end
      @self_hosting_addresses = raw.compact.filter_map { |address| parse_ip(address) }
    end

    def no_host_key_refusal(instance)
      "refusing to run an out-of-band command on instance #{instance.id} — no SSH host key is " \
        "recorded for it, so the host's identity cannot be verified and the command could run on " \
        "whatever host now answers at its address. The node's agent reports its host key on " \
        "heartbeat; confirm the agent is current and heartbeating, then re-submit."
    end

    def nil_pin_refusal
      "refusing to run an out-of-band command — no pinned_ip was supplied at execution time, " \
        "so the repoint-since-approval check cannot run. A nil pin is never legitimate here: the " \
        "gating surface always resolves and freezes the instance's SSH IP before parking " \
        "(not approved)."
    end

    def ip_pin_refusal(instance, pinned_ip)
      "refusing to run an out-of-band command on instance #{instance.id} — its current SSH IP " \
        "(#{instance.ssh_ip_address.inspect}) no longer matches the address pinned when this " \
        "was approved (#{pinned_ip.inspect}). The target may have been repointed since approval; " \
        "re-submit the command against its current address."
    end

    # Execution-time only (security review finding S6) — see class header.
    # The literal phrase "ssh disabled" stays in the message so it is a
    # locatable, greppable audit reason.
    def ssh_disabled?
      !::System::SshExecutionService.ssh_enabled?
    end

    def ssh_disabled_refusal
      "refusing to run an out-of-band command — SSH is disabled (SYSTEM_SSH_ENABLED=false); " \
        "refusing rather than auditing a mocked run as a real one for a governed action " \
        "(ssh disabled)."
    end

    # Execution-time only (security review finding S4) — see class header.
    # The literal phrase "not approved" stays in the message for the same
    # greppability reason as #ssh_disabled_refusal's "ssh disabled".
    def unauthorized_operation_refusal(deferred_operation)
      if deferred_operation.nil?
        return "refusing to run an out-of-band command — no deferred operation was supplied; " \
               "this action must run as the replay of an approved request, never a direct call " \
               "(not approved)."
      end

      unless %w[approved executing].include?(deferred_operation.status)
        return "refusing to run an out-of-band command — operation #{deferred_operation.id} is " \
               "#{deferred_operation.status.inspect}, not approved/executing (not approved)."
      end

      request = deferred_operation.approval_request
      return nil if request&.approved?

      "refusing to run an out-of-band command — operation #{deferred_operation.id} has no " \
        "approved, decided approval request backing it (not approved)."
    end

    # Execution-time only (review finding C2-4) — see class header. Resolved
    # from the operation first, falling back to its approval request
    # (Ai::AutonomyGate#create_approval_request! always copies
    # deferred.requested_by onto the request it opens, so the two agree in
    # the ordinary case; the fallback only matters for a row shaped before
    # that, or a hypothetical caller that populated one but not the other —
    # "and/or its approval request", not "only the operation").
    #
    # `requested_by` covers every shape either door records: the REST door's
    # `current_user`, the MCP door's `user:` (a person's own MCP session), and
    # an agent acting FOR a user (Ai::AutonomyGate.evaluate always threads
    # `requested_by: user` alongside `agent:` — the human the agent acts for
    # is on THIS column either way, never only the agent). Both associations
    # are `belongs_to class_name: "User"`, so an instance principal (mTLS
    # node cert) or a Worker can never legitimately BE the resolved value —
    # neither is backed by the users table this FK points at.
    # #out_of_band_exec_gate_context (MCP) and
    # NodeInstanceGating#gate_out_of_band_exec (REST) already refuse both
    # OUTRIGHT before parking, independently of this check, for the same
    # reason S4 above does not trust the deny overlay alone to hold forever —
    # the `is_a?(::User)` check below still runs rather than trusting "no
    # instance/worker reaches here" as an invariant nothing could ever break.
    def requester_authorization_refusal(deferred_operation)
      requester = deferred_operation.requested_by || deferred_operation.approval_request&.requested_by
      return requester_unresolvable_refusal if requester.nil? || !requester.is_a?(::User)
      return requester_permission_revoked_refusal unless requester.has_permission?(REQUESTER_PERMISSION)

      nil
    end

    # The literal phrase "requester unresolvable" stays in the message for
    # the same greppability reason as #ssh_disabled_refusal's "ssh disabled".
    # Never names the requester or the operation id here — there is no
    # requester to name.
    def requester_unresolvable_refusal
      "refusing to run an out-of-band command — the principal that originally requested it " \
        "cannot be resolved: no requester was recorded, the recorded requester no longer " \
        "exists, or it does not resolve to a person's own account at all. Refusing rather " \
        "than running a command with no accountable requester (requester unresolvable)."
    end

    # `has_permission?`, never `permissions.include?` (the latter returns
    # permission OBJECTS, never a boolean the guard could trust — see
    # CLAUDE.md's Permission-Based Access Control rule). Never names the
    # requester by email/id in a message an executor-lost audience might read
    # more widely than the operator investigating this refusal — the reason
    # is enough to locate them from deferred_operation_id, which the audit
    # row already carries.
    def requester_permission_revoked_refusal
      "refusing to run an out-of-band command — the principal that originally requested it " \
        "no longer holds #{REQUESTER_PERMISSION}. An operator's later approval of the request " \
        "does not stand in for a requester who has since lost the permission this action runs " \
        "under (requester permission revoked)."
    end

    # Non-positive (unset reads as 0 via SiteSetting's integer coercion, and
    # a corrupted or deliberately hostile value could only ever be <= 0 or a
    # huge positive — never negative-as-shell-content, since it is coerced
    # through String#to_i long before this reads it) falls back to the
    # DEFAULT rather than being handed to BoundedCommandRunner, which itself
    # raises ArgumentError on a non-positive value.
    def timeout_seconds
      self.class.configured_timeout_seconds
    end

    def max_output_bytes
      value = ::SiteSetting.get(MAX_OUTPUT_SETTING_KEY).to_i
      value = value.positive? ? value : DEFAULT_MAX_OUTPUT_BYTES
      [ value, MAX_OUTPUT_BYTES_CEILING ].min
    end

    def write_started_audit!(instance:, sudo:, agent_id:, deferred_operation_id:, call_origin:)
      ::AuditLog.create!(
        account: instance.account,
        action: STARTED_ACTION,
        resource_type: "System::NodeInstance",
        resource_id: instance.id.to_s,
        source: "system",
        metadata: {
          sudo: sudo,
          agent_id: agent_id,
          deferred_operation_id: deferred_operation_id,
          call_origin: call_origin
        }.compact
      )
    end

    # Rescued deliberately (see class header): the command has already run
    # by the time this is called, so raising here would misreport a
    # completed action as a failure and give the caller no way to learn
    # what actually happened on the node.
    def write_finished_audit(instance:, sudo:, result:, agent_id:, deferred_operation_id:, call_origin:)
      ::AuditLog.create!(
        account: instance.account,
        action: FINISHED_ACTION,
        resource_type: "System::NodeInstance",
        resource_id: instance.id.to_s,
        source: "system",
        metadata: {
          sudo: sudo,
          success: result.success?,
          exit_code: result.data[:exit_code],
          timed_out: !!result.data[:timed_out],
          truncated: !!result.data[:truncated],
          agent_id: agent_id,
          deferred_operation_id: deferred_operation_id,
          call_origin: call_origin
        }.compact
      )
    rescue StandardError => e
      Rails.logger.error("[OutOfBandExecService] finished-audit write failed: #{e.class}: #{e.message}")
    end

    # Best-effort, deliberately (security review finding S5): the refusal
    # itself is what matters and must fire whether or not this write
    # succeeds, so #execute! calls this and then raises Refused regardless —
    # a broken audit sink must never be a way to silently bypass a refusal by
    # breaking the thing that would have recorded it (it wouldn't: the raise
    # is unconditional either way), but it also must never PREVENT the raise.
    # Never carries the command text — `reason` is always one of this
    # class's own static/near-static refusal messages, never caller input.
    def write_refused_audit!(instance:, reason:, agent_id:, deferred_operation_id:, call_origin:)
      ::AuditLog.create!(
        account: instance.account,
        action: REFUSED_ACTION,
        resource_type: "System::NodeInstance",
        resource_id: instance.id.to_s,
        source: "system",
        metadata: {
          reason: reason,
          agent_id: agent_id,
          deferred_operation_id: deferred_operation_id,
          call_origin: call_origin
        }.compact
      )
    rescue StandardError => e
      Rails.logger.error("[OutOfBandExecService] refused-audit write failed: #{e.class}: #{e.message}")
    end
  end
end
