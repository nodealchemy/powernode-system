# Runbook — Ops-Hub Boot-Image Re-Provision (campaign 019f505f, Inc 5)

> Status: draft — awaiting hardware-validation gate + operator go/no-go before execution.
> **Destructive.** This re-images the running ops-hub VM. Read the whole runbook,
> snapshot first, and do not run the cutover until steps 1–4 of the checklist are green.

## Purpose

One-time re-image of the ops-hub onto the smooth-upgrade-capable disk image, so that
**every future ops-hub boot-image upgrade is in-place** (agent-driven `upgrade_boot_image`
+ A/B systemd-boot rollback, Inc 1–4) rather than a re-provision. The ops-hub's *current*
agent predates Inc 2, so it cannot self-upgrade — this manual first hop is the bridge;
after it, the ops-hub upgrades like any other fleet node.

## Target parameters (verified 2026-07-11)

| Field | Value |
|---|---|
| NodeInstance | `019f4f4e-4abb-7072-ab54-6bb6d757606e` (`ops-hub-20260711035238-6e32`) |
| Node | `019f4ebc-a4d3-7505-8a5b-69e45d25413e` |
| Proxmox VM | **`dna/qemu/102`** (host `dna`, vmid `102`) |
| Arch | amd64 |
| Target image | `git.powernode.org/powernode/disk-images/ubuntu-24.04-amd64-uefi:34f2af6dff33212ba12c403f9eba4e65bfe12073` |
| Target git_sha | `34f2af6dff33212ba12c403f9eba4e65bfe12073` |
| Target sha256 | `46236c442ac141004fb0772f4f280e79fd626da67e29b6099e496931e9dbc9e1` |
| Publication | `019f5329-a593-74c2-b3d2-b9356e852fb9` |
| Platform URL | `https://dev.ipnode.us` |

## Pre-cutover checklist (ALL must be green before touching VM 102)

1. **Hardware-validation gate passed** — the A/B systemd-boot flow (`set-oneshot` → fail
   → auto-revert; `set-oneshot` → healthy → self-bless → `set-default` persists across
   reboots) validated on real UEFI/OVMF. Inc 3 recorded this as mandatory; it cannot be
   exercised in CI. **This runbook must not run until this is confirmed.**
2. **Image promoted** — `34f2af6` set as the amd64 platform default
   (`platform_system_set_default_disk_image_publication`). Promoting also arms the Inc 4
   require-approval drift rollout for other amd64 nodes — expect approval requests; that
   is expected, not a fault.
3. **Cosign public key configured** — `POWERNODE_COSIGN_PUBLIC_KEY` (or `_FILE`) set on
   the platform. `UpgradeDispatcher.platform_blocker` fails closed without it; required
   for the ops-hub's *future* in-place upgrades (not for this re-image itself).
4. **Proxmox protection flag cleared** — `qm set 102 --protection 0` on `dna` (protected
   VMs refuse stop/terminate; see the PVE-protection learning). Re-enable after cutover.

## Path A — preserve /persist (RECOMMENDED)

The campaign is `/persist`-preserving. VM 102's `/persist` holds the agent's enrolled
mTLS cert + node state. If `/persist` survives the re-image, the new agent **reuses the
cert and reconnects as the same instance — no re-enrollment, no fw-cfg, no bootstrap
token**. This is the manual equivalent of the in-place `upgrade_boot_image` the ops-hub
will do on its own from now on.

> **Topology to confirm before executing (operator):** these images are UEFI UKI nodes —
> ESP (FAT, the UKI/boot manager) + a separate `/persist` (ext4) partition. Path A rewrites
> **only the ESP/boot** and leaves `/persist` untouched. Confirm VM 102's disk actually
> has a separate `/persist` partition (not a single rootfs) before choosing Path A; if the
> rootfs is not fully self-contained in the UKI, fall to Path B.

1. **Snapshot** VM 102 for rollback: `qm snapshot 102 pre-34f2af6 --description "pre boot-image re-image 019f505f"`.
2. **Drain / quiesce** any ops-hub workloads you don't want interrupted (this reboots the node).
3. **Stop** the VM: `qm stop 102` (graceful; do **not** use `qm reset`).
4. **Attach the new image** as a scratch disk on `dna` (pull the OCI image to a local
   `.img`, e.g. via `skopeo copy` + the publication's `oci_ref`, verifying `sha256 =
   46236c44…`), then **copy only the ESP** contents (`/EFI/BOOT/BOOTX64.EFI` = systemd-boot
   manager + `/EFI/Linux/<uki>` = the boot-counted UKI slot) onto VM 102's existing ESP,
   leaving the `/persist` partition intact. This converts VM 102 to the new A/B layout in
   one shot while preserving state.
5. **Start**: `qm start 102`.
6. Proceed to **Verification**.

## Path B — fresh identity via fw-cfg (FALLBACK: /persist wiped / clean slate)

Use only if `/persist` is corrupt or a clean re-provision is wanted. This wipes node
state; the agent re-enrolls from injected identity.

Inject identity via QEMU fw-cfg (Proxmox VMs get **no** identity from a bare provision —
the 257a gap — and read it from `/sys/firmware/qemu_fw_cfg/by_name/opt/com.powernode/…`,
**not** cidata). The agent's `FwCfgStrategy` (`agent/internal/identity/fwcfg.go`) reads:

| fw-cfg key (`opt/com.powernode/…`) | Required | Value |
|---|---|---|
| `instance_uuid/raw` | **yes** (else `ErrNotFound`) | `019f4f4e-4abb-7072-ab54-6bb6d757606e` |
| `platform_url/raw` | for enroll | `https://dev.ipnode.us` |
| `ca_pem/raw` | for enroll | **the Let's Encrypt chain** (must be the LE chain, not a leaf) |
| `bootstrap_token/raw` | for enroll | **single-use token minted by the platform** — see secret note |

> **Secret handling.** The `bootstrap_token` is a credential. Obtain it from the platform
> over TLS (re-provision / claim flow for instance `019f4f4e`); write it **only** into the
> fw-cfg file on `dna`. **Never** echo it, put it in shell history, commit it, or paste it
> into logs/this doc. Delete the seed file after `qm start`.

1. `qm snapshot 102 pre-34f2af6 …` (rollback).
2. `qm stop 102`.
3. Write the full `34f2af6` image to VM 102's boot disk (verify `sha256`).
4. Build the CloudSeed fw-cfg files (one file per key above) and attach them:
   `qm set 102 --args "-fw_cfg name=opt/com.powernode/instance_uuid/raw,file=…/instance_uuid \
   -fw_cfg name=opt/com.powernode/platform_url/raw,file=…/platform_url \
   -fw_cfg name=opt/com.powernode/ca_pem/raw,file=…/ca_pem \
   -fw_cfg name=opt/com.powernode/bootstrap_token/raw,file=…/bootstrap_token"`.
5. **`qm stop 102` then `qm start 102`** — a full stop/start so the new `--args` take
   effect. Do **not** `qm reset` (reset does not re-read `--args`).
6. Proceed to **Verification**.

## Verification (both paths)

- **Enroll/reconnect:** `platform_system_get_instance 019f4f4e` — `status=running`, a fresh
  `last_heartbeat_at`, and (Path A) the **same** `mtls_subject`.
- **Boot-image identity (the whole point):** the heartbeat's `booted_image_git_sha ==
  34f2af6dff33212ba12c403f9eba4e65bfe12073`. Confirm via the NodeInstance serializer /
  `platform_system_drift_report` — the ops-hub must **no longer be drifted**.
- **/persist preserved (Path A):** ops-hub state/services intact; no re-enroll occurred.
- **A/B slot healthy:** after the first healthy heartbeat the agent self-blesses the new
  slot and `set-default`s it; a subsequent reboot stays on `34f2af6` (not a fallback).
- **Services up:** ops-hub role services (SDWAN/egress via nftables, etc.) reconcile and
  start; `nft` present in the pivoted rootfs.

## Rollback

If the node fails to boot, enroll, or the new slot doesn't bless:
- **Path A / B:** `qm stop 102 && qm rollback 102 pre-34f2af6 && qm start 102` — restores
  the pre-cutover VM exactly (old image + `/persist`).
- A/B nodes also self-recover: a UKI that fails to boot exhausts its boot counter and
  systemd-boot falls back to the prior good slot automatically (no manual action) — but the
  snapshot is the authoritative rollback for this first-hop where the *old* layout was
  single-slot.
- Re-set `qm set 102 --protection 1` once resolved.

## After the first hop

The ops-hub now runs an Inc-1–4 image. All subsequent boot-image upgrades are **in-place**:
the drift sensor sees it lag a future promote, the Inc 4 rollout (require-approval) or a
direct `upgrade_boot_image` dispatches the agent-side UKI upgrade with cosign verification
and A/B rollback — no re-provision, `/persist` preserved automatically. Inc 5 is a one-time
bridge, not a recurring procedure.

_Draft prepared 2026-07-11. Verify VM/partition specifics on `dna` before executing._
