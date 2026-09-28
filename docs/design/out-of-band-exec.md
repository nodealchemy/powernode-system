# Governed out-of-band exec (IMP-9ce0ed39c557)

A governed, operator-reachable way to run ONE command on a node over SSH,
from the control plane, without that node's own agent — closing a real gap:
`ssh_command` `System::Task`s are delivered only to a live agent,
`System::SshExecutionService` was reachable from ~40 in-process services with
no gate of its own, and the only "door" for arbitrary out-of-band SSH
(`ssh_exec`/`ssh_sync`/`ssh_cleanse` on
`Api::V1::Internal::System::NodeInstancesController`) was unrouted dead code
behind worker-token auth alone, with no approval gate, no audit trail, and no
bound on runtime or output.

## Surfaces

Two doors, one gated primitive:

- MCP verb `system_out_of_band_exec` (`Ai::Tools::SystemFleetTool`)
- REST operator endpoint `POST /api/v1/system/nodes/:node_id/node_instances/:id/out_of_band_exec`

Both go through `Ai::AutonomyGate.evaluate` into the same executor,
`System::Executors::OutOfBandExec`, which delegates every refusal check,
audit write and the actual bounded SSH call to `System::OutOfBandExecService`.

## Approval is human-only

`system_out_of_band_exec` is declared `human_only: true`
(`Ai::Tools::SystemFleetTool`), and the REST door passes
`requires_human_session: true` into the same `Ai::AutonomyGate.evaluate` call
directly (security review finding S1). Both mean:

- **No policy row can auto-approve it.** `Ai::AutonomyGate#evaluate` forces
  `auto_approve`/`notify_and_proceed` to `require_approval` whenever
  `requires_human_session` is set, regardless of what the resolved policy
  says — an operator cannot accidentally (or deliberately) configure this
  category to run with no person confirming it.
- **No tool door can approve it either.** The opened `Ai::ApprovalRequest`
  carries `requires_human_session: true`, and every existing decision door
  already refuses any such request —
  `Ai::Tools::AgentAutonomyTool#approve_deferred_operation` /
  `#reject_deferred_operation` return a refusal naming the Autonomy dashboard
  instead of deciding it. An agent, an MCP client, or a compromised
  connector holding `ai.autonomy.approve` cannot approve its own (or
  another agent's) out-of-band-exec request; only a person deciding through
  their own REST/UI session can.
- **The REST request door itself is human-only too** (security review finding
  S3) — `NodeInstanceGating#gate_out_of_band_exec` refuses outright when
  `current_worker` is present, which covers both worker-JWT and
  forwarded-mTLS-client-cert authentication (`MtlsClientAuthentication` sets
  the same attribute either way). A worker or node certificate — credentials
  that live node-adjacent and are more likely to be compromised alongside a
  node itself — cannot even FILE the request, let alone decide it.

## Governance category

`system.instance.out_of_band_exec` — **not** a reuse of
`system.task.ssh_command`, so an operator who auto-approves in-band SSH
tasks has not unknowingly auto-approved this too. Declared outside
`PolicyDeclarations::POLICY_SETS` (in `PolicyReconciler#out_of_band_exec_set`,
alongside `#manual_set`), because it has no natural owning agent — the same
reason `system.task.ssh_command` itself sits outside `POLICY_SETS`
(`PolicyDeclarations.owner_of` returns `nil` for both). `scope: "global"` is
agent-binding by design (`Ai::InterventionPolicyService`), so this one row
governs an operator and an agent caller alike. Defaults to `require_approval`.

## Refusal layers (defense in depth)

`System::OutOfBandExecService#refusal` is checked BOTH at request time (the
gate-context preflight on each door, before ever parking) AND again at
execution time (`#execute!`, immediately before the SSH call) — a target or
configuration that changes between the two is caught either way:

1. **Instance-principal deny overlay** (core) —
   `Mcp::Principal::DESTRUCTIVE_TOOL_PATTERNS` denies `system_out_of_band_exec`
   outright to every instance principal, whatever it was granted.
2. **Gate-context refusal** (extension) — both
   `SystemFleetTool#out_of_band_exec_gate_context` and the REST controller
   action independently refuse an instance principal / worker or node-cert
   principal (REST only, S3) / blank ssh_ip_address / blank command, on their
   own, without relying on layer 1 staying intact (mirrors
   `#dr_lane_reap_by_instance_principal!`'s own reasoning).
3. **Blank or secret-shaped command** — a command containing inline
   secret-shaped material (anything `System::ShellOutputSanitizer` would
   redact — a password, token, key, credential URL, …) is refused before
   ever being parked or shown to an approver. The refusal message never
   echoes the command.
4. **INV-1 self-management fence** — `System::Autonomy::SelfManagementFence`
   refuses a target that IS this control plane's own hosting node.
5. **Self-hosting FAILS CLOSED when unconfigured** (security review finding
   S2) — unlike `SelfManagementFence`'s own inert-by-default for every other
   consumer (unset reasonably reads as "not self-hosted" elsewhere),
   out-of-band-exec refuses outright when
   `SiteSetting[self_hosting_node_id]` is blank: for a feature that runs
   arbitrary root commands over SSH, "we cannot tell whether this is our own
   node" must refuse, not silently allow.
6. **Unsafe target address** (security review findings S2 / R2-1) —
   loopback, link-local, unspecified (`0.0.0.0`, `::`), broadcast
   (`255.255.255.255`), multicast, or one of this control plane's own
   addresses (every real IP any instance on the self-hosting node
   advertises, plus `System::Node#public_address` when the node records
   one). Every check runs on the PARSED `IPAddr`, never the raw string — an
   IPv4-mapped IPv6 spelling of a control-plane address (`::ffff:<hub ip>`)
   is normalized to its embedded IPv4 form first (`IPAddr#ipv4_mapped?` /
   `#native`), and a non-canonical IPv6 spelling of the same address still
   compares equal under `IPAddr#==`. The own-addresses check is keyed on the
   address VALUE, independent of `#self_managed_target?`'s node-id check —
   catches a target whose IP happens to coincide with the self-hosting
   node's even if its declared `node_id` does not (e.g. after a repoint —
   IP fields are writable through `system_update_instance`, which is
   ungated, and through the REST update endpoint).
7. **The IP pin** — the instance's SSH IP is resolved and frozen into the
   operation at gate time (`pinned_ip`), and named on the approval
   card/description itself (R2-1) so the approver sees WHERE it will
   actually run, not just the instance's name. If the instance is repointed
   to a different address between an approval request being parked and a
   person approving it, execution is refused rather than silently following
   the new address. A nil pin at execution time is ALSO refused outright
   (R2-2) rather than treated as "no pin supplied, skip the check" — a
   legitimately parked operation always carries one, so its absence at
   execution time means a bypass of the normal gate.
8. **SSH disabled** (security review finding S6, execution-time only) — when
   `SYSTEM_SSH_ENABLED=false`, `#execute!` refuses outright rather than
   letting `SshExecutionService`'s test-env mock convenience (built for the
   ~40 unrelated `#execute` callers) report a mocked "it worked" as if a real
   command had run.
9. **Operation authorization** (security review finding S4, execution-time
   only, defense in depth) — `#execute!` asserts the `Ai::DeferredOperation`
   it is running for is itself `approved`/`executing` and backed by a
   DECIDED, APPROVED `Ai::ApprovalRequest`, refusing a hypothetical direct
   call that bypassed `Ai::AutonomyGate` entirely.
10. **The requester's own authorization, re-checked** (review finding C2-4,
    execution-time only) — layer 9 asks whether the operation is approved;
    this asks whether the principal that originally REQUESTED it may still
    be trusted to have, now. Every OTHER `human_only` action replays through
    `Ai::Executors::DeferredToolCall`, which re-authorizes its confirming
    approver before it runs — but this action's `executor_class` is its own
    `System::Executors::OutOfBandExec`, never `DeferredToolCall`, so that
    generic re-check never fires for it: `Ai::DeferredOperation#execute_now!`
    calls straight into this service. Without this layer, a requester whose
    `system.instances.control` was revoked between park and approval still
    got their command run, on the strength of a decision made about a
    request that was authorized only at the moment it was filed.
    `#requester_authorization_refusal` resolves the original requester from
    `deferred_operation.requested_by`, falling back to
    `approval_request.requested_by` — the same column both doors set
    (`Ai::AutonomyGate.evaluate`'s `requested_by:`, which is the human even
    when an agent is acting for them) — and refuses when it cannot be
    resolved at all (fails closed) or no longer holds the permission.

Every refusal from `#execute!` (layers 3–10 above, when reached at execution
time) writes an audited `REFUSED` row — see Audit below (security review
finding S5). The bare `#refusal` predicate used by the request-time preflight
writes nothing: it is a read-only check, before anything has been attempted.

## The bounded runner

`System::SshExecutionService#execute_bounded` is a **separate, opt-in**
method — the ~40 existing in-process callers of `#execute` are untouched.
It builds the `ssh` argv (`BatchMode=yes`, `ServerAliveInterval`, the
existing F5-01 host/key validation) and delegates the actual process
management to `System::BoundedCommandRunner`, which enforces:

- a **local deadline** (`timeout_seconds`): the local `ssh` client's whole
  process group is SIGTERM'd then SIGKILL'd on expiry, and the result
  reports `timed_out: true` with no exit code;
- a **per-stream output cap** (`max_output_bytes`, stdout and stderr
  independently): output beyond the cap is discarded and the result reports
  `truncated: true`.

Killing the local `ssh` client alone does **not** stop the command on the
node: without a pty, sshd never signals the remote side when the client
disconnects, so a plain `ssh host 'sudo <command>'` whose local client is
killed leaves `<command>` running as root on the node indefinitely. The
authoritative bound is therefore on the **remote** side —
`execute_ssh_command_bounded` wraps the command itself in GNU coreutils
`timeout -k 5 <timeout_seconds> sh -c '<command>'` (with `sudo` applied
outermost when requested, so `timeout` runs as root and can signal a
root-owned process group), and only then runs that string over `ssh`.
`timeout` starts the wrapped command in its own process group on the node
and kills that whole group on its own timer, independent of what happens to
the local `ssh` client. The local kill described above is a second,
best-effort layer bounding the client process on THIS host — it is not a
substitute for the remote one.

## The two SiteSettings

| Key | Type | Default | Hard ceiling | Holds |
|---|---|---|---|---|
| `system.out_of_band_exec.timeout_seconds` | integer | 120 | 300s | a number of seconds |
| `system.out_of_band_exec.max_output_bytes` | integer | 65536 (64 KiB) | 1 MiB | a byte count |

Both are registered via `Ai::Tools::SiteSettingTool.register_key` — **never
hardcoded** — so an operator can tune them from the Autonomy / Settings
surface like any other SiteSetting. Both are also **clamped**, not merely
defaulted (review findings #6 / R2-3): a configured value above its ceiling
degrades to the ceiling rather than being honored unbounded — an
operator-tunable setting with no ceiling is "no bound" again, defeating the
point of a BOUNDED runner. `System::OutOfBandExecReaperService` computes its
own staleness threshold from the SAME public
`System::OutOfBandExecService.configured_timeout_seconds` (review finding
C2-2) rather than duplicating the read-and-clamp logic, so the two never
drift out of step.

**Neither setting ever holds a command, an allowlist, a credential, or any
other secret.** They are pure numeric bounds. `SiteSetting.get` coerces a
`setting_type: "integer"` value through `String#to_i` before
`OutOfBandExecService` ever sees it (`value.positive? ? value : DEFAULT_*`),
so:

- a non-numeric or corrupted stored value degrades to `0`, which reads as
  "unset" and falls back to the compiled-in default — it is never passed
  through to a shell in any form;
- there is no interpolation path from either setting's stored value into the
  `ssh` argv or the remote command string at all. The command itself always
  comes from the caller's own request (`params[:command]`), gated and
  audited on its own; these two settings only ever bound HOW LONG and HOW
  MUCH, never WHAT.

If a future setting under this feature ever needs to hold something
shell-interpreted (an allowlist pattern, for example), it must NOT be added
to this pair without a fresh review of this document — the guarantee above
holds only for the two rows named here.

## Command text

**Decision (security review): kept, deliberately.** The command is stored in
the parked `Ai::DeferredOperation#params` and shown to the approver on the
approval request/card, same as every other gated action's params — an
approver confirming a `human_only` action (see above) must see what they are
authorizing, not a redacted stand-in. The approval card's fixed IMPACT
sentence (`System::Executors::OutOfBandExec#impact`) does not itself embed
the command in its prose — that stays a short, skimmable line regardless of
command length — but the underlying stored `command` param is not hidden
from the approver.

What the command is NOT shown in: neither the `STARTED` nor `FINISHED`
`AuditLog` row ever carries it (see Audit below), and
`SshExecutionService#execute_bounded`'s log lines never carry it either (only
the instance id, timeout/cap on entry, and `exit_code`/`timed_out`/`truncated`
on exit). The one guard on the command ITSELF is the secret-shaped check
(refusal layer 3 above): a command that carries inline secret-shaped
material is refused before ever being parked or shown to anyone, and that
refusal's own error message never echoes the command — refusing it must not
become a second way to leak it.

## Output persistence (corrected, C2-6)

`#execute!`'s returned hash (including redacted `stdout`/`stderr`) is **not**
a one-time value that vanishes once the call returns:
`Ai::DeferredOperation#execute_now!` persists it into
`DeferredOperation#result` (through `Ai::SensitiveParams.filter`), so the
redacted output is durably readable on the operation afterward. The
`AuditLog` rows below are a stricter, SEPARATE promise ("never the command or
output, ever") — not the only place a caller can see what ran.

## Audit

Up to three `AuditLog` rows per `#execute!` call, all scoped to the
instance's own account, none ever carrying the command text or a credential:

- **STARTED** — written **before** the bounded SSH call runs. **Fail-closed**:
  if this write fails, the whole call raises and the command never runs.
  Records `sudo`, `agent_id`, `deferred_operation_id`, `call_origin`.
- **FINISHED** — written after the call returns. **Best-effort**: rescued
  and logged, never raised — by the time this runs the command has already
  executed, and refusing here would only hide that it did. Records the same
  metadata plus `success`, `exit_code`, `timed_out`, `truncated`.
- **REFUSED** (security review finding S5) — written whenever `#execute!`
  refuses instead of running (self-host, unsafe IP, SSH disabled, not
  approved, secret-shaped command, …). **Best-effort**, same reasoning as
  FINISHED but sharper: the refusal itself must fire whether or not this
  write succeeds, so it is rescued-and-logged and `#execute!` raises
  `Refused` unconditionally afterward — a broken audit sink must never be a
  way to make a refusal look like it didn't happen, nor a way to block the
  refusal from happening. Records `reason` (one of this class's own static
  refusal messages — never caller input, so never the command), plus
  `agent_id`, `deferred_operation_id`, `call_origin`.

## The reaper

`System::OutOfBandExecReaperService`, called every 5 minutes by
`OutOfBandExecReaperJob` (worker) through
`POST /api/v1/system/worker_api/out_of_band_exec/reap` (server), fails any
`Ai::DeferredOperation` stuck `executing` under this category past
`timeout_seconds` + a 60s margin, with `error_message: "executor lost"` and
an `Ai::ExecutionEvent`. **It never re-runs the command** — a stuck row
means the process that was running it is gone, and replaying an out-of-band
shell command a second time with no visibility into whether the first one
completed is a correctness and safety hazard this design does not take on.

## What was removed

`ssh_exec` / `ssh_sync` / `ssh_cleanse` on
`Api::V1::Internal::System::NodeInstancesController`, and
`System::SshExecutionService.cleanse`/`#cleanse` (its only caller). Verified
unrouted and uncalled before removal; not resurrected as the governed door —
that is everything documented above instead.

## Known limits

Named here rather than silently left for a future reader to rediscover
(security review):

- **SSH host keys are not verified.** `execute_ssh_command_bounded` still
  sets `StrictHostKeyChecking=no` / `UserKnownHostsFile=/dev/null`, same as
  `#execute`. Tracked as **IMP-190834701b0a**, approved separately — out of
  scope for this design.
- **An operation can be stranded `approved`** if the process advancing it
  from `approved` to `executing` dies in between (a crash, a deploy, a
  killed worker). The reaper (above) only ever catches a row already
  `executing`; nothing currently sweeps one stuck `approved`. Tracked as
  **IMP-0213523480d1**, filed separately — out of scope for this design.
- **`ShellOutputSanitizer.secret_shaped?` is best-effort and trivially
  bypassed by encoding** (base64, hex, string concatenation/interpolation
  built at shell-execution time, etc.) — it pattern-matches the LITERAL
  command text handed to it, nothing more. It stops an accidental inline
  secret from being parked and shown to an approver; it is not a content
  security boundary against a deliberate attempt to hide one.
- **A command can escape the remote `timeout` wrapper.** `setsid`,
  `nohup`, or `systemd-run` (among others) can detach a child into a new
  session/scope the wrapping `timeout -k` process group does not reach,
  leaving it running past the deadline despite the wrapper reporting
  `timed_out: true`. The bound this design provides is on the WRAPPED
  command as given, not on every process shape a sufficiently adversarial
  command could construct.
- **The own-addresses fence only covers this control plane's RECORDED
  addresses** (instance IP fields plus `System::Node#public_address`) — an
  unrecorded hub address such as a Docker bridge IP or a second NIC is not
  in that set and relies instead on the node-id fence (INV-1) and on the
  pinned IP being shown to the approver.
