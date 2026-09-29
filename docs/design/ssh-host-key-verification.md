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
  the opened descriptor.
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
  "recorded_at": "<iso8601>", "boot_id": "<boot id of the reporting heartbeat>" }
```

`System::SshHostKeys` re-validates every entry on the way in. Malformed,
oversized, duplicate and injected entries are dropped. A report with no valid
entry leaves the recorded keys untouched and never errors the heartbeat. The
heartbeat block is wrapped in a rescue like every other ingest block there.

`NULL` means the agent has never reported a key. The connection policy below
keys on this.

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
- Every **change** writes `system.ssh_host_key.changed` and a
  **high-severity** fleet event `system.instance.ssh_host_key_changed`.
- Both carry fingerprints only: `previous_fingerprints` → `fingerprints`,
  plus `key_types`. A change also records `boot_id_changed`.
- No key blob and no private material is ever logged.
- The fingerprint uses the `SHA256:` form that `ssh-keygen -l` prints, so an
  operator can match an audit row against the node itself.
- The column write and the audit row share one transaction, so a key is never
  trusted without its audit row.

**Operator surfacing.** A key change should reach an operator, and it does, as
a high-severity event on the fleet event feed. The `boot_id_changed` flag is
what tells the two causes apart:

- **With a reboot** (`boot_id_changed: true`), a new key is what a reimage or
  reprovision looks like.
- **Without a reboot** (`boot_id_changed: false`), a changed host key has no
  routine explanation. Treat it as a possible impersonation, or as a
  compromised agent certificate, and investigate before trusting the node.

Nothing pages on this event today. A fleet sensor that turns an unexplained
change (no reboot) into a governed signal is the natural follow-up. It was
left out of this change to keep the scope to verification.

## The connection policy

For every path, `SshExecutionService` re-validates the recorded keys. It then
writes them into a **per-call known_hosts tempfile** with mode 0600, deleted in
`ensure` on success and on error alike, and connects with:

```
-o StrictHostKeyChecking=yes
-o UserKnownHostsFile=<tempfile>
-o GlobalKnownHostsFile=/dev/null
-o HostKeyAlias=powernode-node-instance-<instance id>
-o CheckHostIP=no
-o UpdateHostKeys=no
```

`HostKeyAlias` keys the entry on the **instance**, not the address. A node
whose IP changes still matches its own key. A different host at the same IP
cannot match it, because the file holds only this instance's keys.
`CheckHostIP=no` and `UpdateHostKeys=no` stop ssh from adding its own entries.

| Path | Key recorded | No key recorded |
|---|---|---|
| Out-of-band exec (`#execute_bounded`, `System::OutOfBandExecService`) | strict | **refused**, always. `OutOfBandExecService#refusal` refuses before anything is parked for approval, and `#execute_bounded` refuses again as a backstop. |
| Legacy callers (`#execute`, `#scp_file`, `#sync`) | strict, immediately, whatever the setting | `system.ssh.require_host_key` **off** (default): connect unverified as before, log a warning, and emit a medium `system.instance.ssh_host_unverified` fleet event (at most one per instance per hour). **on**: refused. |

The setting `system.ssh.require_host_key` is a `SiteSetting` boolean,
registered on the MCP settings verb as **protected**. Turning host
verification off again is a person's decision. If the setting cannot be
read, the service treats it as on and refuses.

## Migration order

1. **Deploy the agent** that reports `ssh_host_keys` (with the platform
   change, which is backward compatible: a pre-feature agent's heartbeat
   simply has no block).
2. **Keys populate on heartbeat.** Each node's first report is audited as
   `system.ssh_host_key.recorded`. Legacy callers keep working throughout,
   verified strictly as soon as a node has reported.
3. **Verify coverage.** Every node the platform SSHes into must have a
   recorded key: running instances with `ssh_host_keys IS NULL` should be
   zero. The `system.instance.ssh_host_unverified` events name any node a
   legacy caller still reached unverified.
4. **Flip `system.ssh.require_host_key` to true.** From then on, a node with
   no recorded key is refused on every path.

Out-of-band exec does not wait for step 4. It refuses unverified hosts from
the moment the platform change deploys, so nodes stay unreachable by
out-of-band exec until their agent reports a key.
