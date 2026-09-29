# SSH host key verification (IMP-190834701b0a)

`System::SshExecutionService` is the single SSH/SCP substrate for the control
plane. Governed out-of-band exec uses it, and so do the sync, maintenance,
module-commit, code-deploy and storage paths. Until this change, every
connection it made passed `StrictHostKeyChecking=no` and
`UserKnownHostsFile=/dev/null`. The out-of-band IP pin proves the database
record was not repointed. It does not prove which host answers at that
address. VMID and IP reuse is routine in this fleet, so a root command could
run on whatever host now held the recorded address.

Now every connection verifies the host against keys the node itself reported.

## Where the keys come from

The agent reads `/etc/ssh/ssh_host_*_key.pub` on every heartbeat
(`agent/internal/runtime/hostkeys.go`) and sends each valid key as
`{type, key}` in the heartbeat's `ssh_host_keys` block.

- **Only `*.pub` is ever opened.** The reader globs `ssh_host_*_key.pub` and
  refuses anything that is not a regular file. A symlinked `.pub` could point
  at the private key beside it, so the open uses `O_NOFOLLOW` and re-checks
  the opened descriptor. Before opening, it also refuses a `.pub` that is not
  world-readable (private keys are 0600) and a `.pub` that is a hardlink to
  the private key beside it, so a private key's bytes are never read.
- **Nothing is reported from the initramfs.** The initramfs generates fresh,
  ephemeral host keys on every boot before `switch_root`, and recording them
  would make every pivoting boot look like a key change. The agent reports
  only when `/etc/initrd-release` is absent and `/` is neither ramfs nor
  tmpfs. That covers the pivoted overlay root and a cloud_init disk root. An
  unreadable root probe counts as initramfs, so nothing is reported.
- The content must be one printable line, `<type> <base64> [comment]`.
  The type must be on the allowlist (ed25519 first, then ECDSA, the
  security-key forms, and RSA). The base64 must be strict, and the blob's
  embedded algorithm name must match the declared type. Content shaped like
  a private key is refused. Files are capped at 8 KiB and keys at 4096
  base64 characters. The comment is dropped.
- A refused file is reported once through the agent's error hook, with the
  path and the reason and never the file content.
- No valid key means the block is omitted, which reads as NOT MEASURED. It
  is never sent as an empty list.

## Where they are stored

`System::SshHostKeyWriter` ingests the block from
`StatusController#heartbeat` into `system_node_instances.ssh_host_keys`, a
dedicated JSONB column:

```json
{ "keys": [ { "type": "ssh-ed25519", "key": "<base64>", "fingerprint": "SHA256:<unpadded base64>" } ],
  "recorded_at": "<iso8601>", "boot_id": "<last boot on which these keys were confirmed>" }
```

`System::SshHostKeys` re-validates every entry on the way in. Malformed,
oversized, duplicate and injected entries are dropped. A report with no valid
entry leaves the recorded keys untouched and never errors the heartbeat. The
heartbeat block is wrapped in a rescue like every other ingest block there.

`NULL` means the agent has never reported a key. The connection policy below
keys on this.

Keys are ingested only when the certificate identity is **bound to this
instance**: `mtls_subject` is blank or equals the instance id. The node API
resolves a legacy shared-hostname certificate CN to the newest sibling
instance, so such a report could write one instance's key onto another. It is
skipped with a warning.

The read, compare and write run under the instance row lock, so a retried
heartbeat that overlaps its original cannot record twice.

## Trust, change and audit

The heartbeat is mTLS-authenticated. Only the holder of the instance's client
certificate can post it, and that channel is the trust anchor. A **changed**
key is accepted from it, because a reimaged node legitimately gets new host
keys and only its own agent can say so.

Accepting a change quietly would also hide the other cause: a different host
now holding the instance's identity. So:

- The **first recording** writes an `AuditLog` row
  `system.ssh_host_key.recorded` and a low-severity fleet event
  `system.instance.ssh_host_key_recorded`.
- Every **change** writes `system.ssh_host_key.changed` and a fleet event
  `system.instance.ssh_host_key_changed`. It is **medium** when the change
  crosses a reboot and **high** when it happens inside one boot (see below).
- Both carry fingerprints only: `previous_fingerprints` → `fingerprints`,
  plus `key_types`. A change also records `boot_id_changed`.
- No key blob and no private material is ever logged.
- The fingerprint uses the `SHA256:` form that `ssh-keygen -l` prints, so an
  operator can match an audit row against the node itself.
- The column write and the audit row share one transaction, so a key is never
  trusted without its audit row.

**Boot classification.** The stored `boot_id` is the last boot on which the
recorded keys were confirmed. An unchanged report on a new boot refreshes it,
at most once per reboot and without an audit row. A change is then compared
against the boot the OLD keys were last seen on:

- **Across a reboot** (`boot_id_changed: true`, medium): what a reimage, a
  reprovision, or a node without `/persist` that rekeys on every boot looks
  like.
- **Inside one boot** (`boot_id_changed: false`, high): the rootfs keys
  changed while the node stayed up. That has no routine explanation.

**What boot_id can and cannot tell you.** `boot_id` is reported by the same
agent, over the same certificate, as the key itself. It separates accidents
from each other (a reimage from a config-management run rewriting keys
mid-boot). It is **not** evidence against an attacker who holds the
instance's certificate, because that attacker can send any boot_id along
with the swapped key. A medium-severity change is therefore not proof of a
benign reimage. It only means the report is consistent with one.

**Narrowed reports.** A report whose keys are a strict subset of the recorded
set, on the same boot, is most likely a transiently unreadable `.pub` file.
It does not replace the recorded set and is not audited (debug log only). The
recorded set narrows only across a boot change, audited as a change.

**Operator surfacing.** Changes reach the fleet event feed at the severities
above. Nothing pages on them today. A fleet sensor that turns an in-boot
change into a governed signal is the natural follow-up. It was left out of
this change to keep the scope to verification.

## The connection policy

For every path, `SshExecutionService` re-validates the recorded keys. It then
writes them into a **per-call known_hosts tempfile** with mode 0600, deleted in
`ensure` on success and on error alike, and connects with:

```
-F /dev/null
-o StrictHostKeyChecking=yes
-o UserKnownHostsFile=<tempfile>
-o GlobalKnownHostsFile=/dev/null
-o HostKeyAlias=powernode-node-instance-<instance id>
-o CheckHostIP=no
-o UpdateHostKeys=no
-o VerifyHostKeyDNS=no
```

`HostKeyAlias` keys the entry on the **instance**, not the address. A node
whose IP changes still matches its own key. A different host at the same IP
cannot match it, because the file holds only this instance's keys.
`CheckHostIP=no` and `UpdateHostKeys=no` stop ssh from adding its own entries.

`-F /dev/null` stops every ssh_config file (the service user's
`~/.ssh/config`, `/etc/ssh/ssh_config` and its drop-ins) from adding a trust
source the tempfile does not control, such as `KnownHostsCommand`,
`VerifyHostKeyDNS`, `Include` or `Match exec`. Nothing in these connections
depends on a config file: the user is in the destination (`user@host`), the
key is passed with `-i`, the port is the default 22, and there is no
ProxyJump. The unverified legacy fallback keeps its old options unchanged.

**Mismatch.** When the host presents a key that is not recorded, ssh exits 255
with `Host key verification failed`. Every path turns that into an explicit
error naming the instance and its recorded fingerprints (`data.host_key_mismatch:
true`), and emits a high-severity `system.instance.ssh_host_key_mismatch` fleet
event (at most one per instance per 15 minutes). That is what a
man-in-the-middle looks like, and also what a stale key looks like.

| Path | Key recorded | No key recorded |
|---|---|---|
| Out-of-band exec (`#execute_bounded`, `System::OutOfBandExecService`) | strict | **refused**, always. `OutOfBandExecService#refusal` refuses before anything is parked for approval, and `#execute_bounded` refuses again as a backstop. |
| Legacy callers (`#execute`, `#scp_file`, `#sync`) | strict, immediately, whatever the setting | `system.ssh.require_host_key` **off** (default): connect unverified as before, log a warning, and emit a medium `system.instance.ssh_host_unverified` fleet event (at most one per instance per hour). **on**: refused. |

The setting `system.ssh.require_host_key` is a `SiteSetting` boolean,
registered on the MCP settings verb as **protected**. Turning host
verification off again is a person's decision. If the setting cannot be
read, the service treats it as on and refuses.

**The stale-key window.** When a node's host keys change across a reboot
(a node without `/persist`, a reprovision), the recorded keys are stale from
the moment sshd starts with the new keys until the agent's next heartbeat
records them: boot time plus up to one heartbeat interval (about 30 s). In
that window every path fails with the mismatch error above. If the agent
never heartbeats (it cannot enroll, or it is down), the window does not close
on its own; see the recovery below.

## Recovery: clearing a stale recorded key

If a node's recorded key is stale and its agent cannot report the new one,
every path fails with a host key mismatch, including out-of-band exec, which
is the tool for diagnosing exactly that agent. The recovery is an
operator-only, audited clear, run from a console on the control plane:

```ruby
System::SshHostKeyWriter.clear!(
  instance: System::NodeInstance.find("<instance id>"),
  actor:    User.find_by!(email: "<operator email>"),
  reason:   "<why the recorded key is stale>"
)
```

It writes a `system.ssh_host_key.cleared` audit row (previous fingerprints,
the operator and the reason; never a key) and a medium
`system.instance.ssh_host_key_cleared` fleet event. Consequences:

- While `system.ssh.require_host_key` is **off**, legacy callers connect to
  the node **unverified** until its agent records a key again.
- While it is **on**, legacy callers are refused.
- Out-of-band exec stays **refused** until the node's next heartbeat records
  a key. Clearing does not make an unverified node reachable by it.

Check the node's key out of band (console or guest agent: `ssh-keygen -lf
/etc/ssh/ssh_host_ed25519_key.pub`) before trusting whatever it reports next.
A human-only verb for this is a follow-up.

## Migration order

1. **Deploy the agent** that reports `ssh_host_keys` (with the platform
   change, which is backward compatible: a pre-feature agent's heartbeat
   simply has no block).
2. **Keys populate on heartbeat.** Each node's first report is audited as
   `system.ssh_host_key.recorded`. Legacy callers keep working throughout,
   verified strictly as soon as a node has reported.
3. **Verify coverage.** Every node the platform SSHes into must have a
   recorded key: among the running instances the platform actually SSHes
   into, those with `ssh_host_keys IS NULL` should be zero. The
   `system.instance.ssh_host_unverified` events name any node a legacy caller
   still reached unverified. Nodes that never leave the initramfs (no module
   union to pivot into) never report a key, by design, because their keys
   are ephemeral. After step 4 they are refused on every path.
4. **Flip `system.ssh.require_host_key` to true.** From then on, a node with
   no recorded key is refused on every path.

Out-of-band exec does not wait for step 4. It refuses unverified hosts from
the moment the platform change deploys, so nodes stay unreachable by
out-of-band exec until their agent reports a key.
