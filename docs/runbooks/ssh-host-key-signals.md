# SSH host key signals

> Status: active
> Audience: on-call SREs, security operators
> Prerequisites: `system.instances.read` to read the signals;
> `system.instances.control` to request a key clear, and a person's own
> session to approve it
> Runtime: ~5 min per signal; longer when a node has to be verified out of band

Every node agent reports its SSH host key on heartbeat, and
`System::SshHostKeyWriter` records it against the instance. The platform's SSH
paths and out-of-band exec verify a host against that recorded key.
`SshHostKeySensor` reads what the writer recorded and raises three signal
kinds. None of them has an applier. The sensor never changes a key or a
setting; a person decides.

Read the live signals with:

```javascript
platform.system_recent_signals({ kind: "system.ssh_host_key_changed_in_boot", limit: 20 })
platform.system_recent_signals({ kind: "system.ssh_host_key_uncovered", limit: 20 })
```

## Host key changed within one boot

`system.ssh_host_key_changed_in_boot` fires when a recorded host key changed
and the agent reported the **same `boot_id`** before and after. A reimaged node
legitimately gets new keys, but it also gets a new boot. A change with no boot
in between has no routine explanation, so treat it as impersonation or
tampering until you have shown otherwise. The `boot_id` is self-reported by the
same agent that reports the key. That makes the signal good at separating
accidents from real changes, but it is not proof against an attacker.

The signal is routed under `require_approval` with no applier. It stays a
live signal for the sensor's `change_lookback_seconds` (one hour by default),
and you get one signal per change event.

1. Verify the node out of band: hypervisor or provider console, or physical
   access. Compare the host key fingerprint the node actually serves with the
   one now recorded. The signal payload carries fingerprints only, never key
   material.
2. If you can't explain the change, isolate the node. Cordon it
   (`system_cordon_instance`), detach it from SDWAN, and keep it out of
   service until it has been rebuilt.
3. Clear the recorded key only once the node's real key is verified (next
   section). Clearing it makes the platform accept whatever the agent reports
   on its next heartbeat.

## Clearing a recorded host key

`system_clear_ssh_host_key({ instance_id })` is a recovery step, not a routine
one. It is human-only and approval-gated (`system.instance.ssh_host_key_clear`).
It returns `{pending: true, requires_human_session: true}` and clears nothing
until a person approves the request in their own session. The approver is the
audited actor (`system.ssh_host_key.cleared`, recording the previous
fingerprints and the reason). No verb pins a key: the agent records its own key
on its next heartbeat. Out-of-band exec stays refused until that happens.

## Instances with no recorded host key

`system.ssh_host_key_uncovered` lists the running or starting instances with no
recorded key, once their first-heartbeat grace has passed (`grace_seconds`,
30 minutes by default). It is notify-only. For each named instance, find out
why its agent is not reporting a key:

- The agent is not heartbeating at all. That is the instance-silence lane
  (`system.instance_silent`); see
  [node-provisioning.md](./node-provisioning.md#per-state-error-recovery).
- The agent heartbeats under a shared legacy mTLS subject, whose key reports
  are never ingested. Fix or retire that instance; it reads as uncovered until
  you do.

This lane is separate from the key-change lane above, so resolving one does
not dismiss the other.

## Fleet coverage complete

`system.ssh_host_key_coverage_complete` is the positive fact: a non-empty fleet
in which no instance is uncovered and none is still inside its grace. It is
routed to `system.observation` (auto-approve), so it files for dashboards and
pages no one. A fleet with no instances raises neither this signal nor the
uncovered one.

Its payload carries `ready_to_enforce` and the current
`system.ssh.require_host_key` value. Turning `require_host_key` on (unverified
hosts are then refused rather than connected to) is your call. Keep in mind
what "covered" means: a key is recorded for every instance. It does not mean
the key is current, because a reimaged node whose agent cannot heartbeat its
new key still reads as covered. It also does not mean the agent is alive.

## Related docs

- [node-provisioning.md](./node-provisioning.md): instance states and
  silent-instance recovery
- [template-authoring.md](./template-authoring.md): the `legacy_rsa_keys`
  template option
