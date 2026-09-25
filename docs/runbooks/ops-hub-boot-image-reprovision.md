# Runbook — Ops-Hub Boot-Image Re-Provision (campaign 019f505f, Inc 5)

> **Placeholders.** Names like `<ops-hub-host>`, `<ops-hub-ip>`, `<pve-host>`, `<dev-host>`,
> `<gitea-host>`, `<hub-vmid>`, `<ops-hub-node-id>` and `<ops-hub-instance-id>` stand in for this
> deployment's real values, which are deployment-local and never tracked in git. Recall them with
> `search_knowledge tag:deployment-ops-hub` (the hub's VM, host and node/instance ids) or
> `tag:deployment-*` on the deployment's platform (see
> [conventions/deployment-knowledge.md](https://github.com/nodealchemy/powernode-platform/blob/develop/docs/contributing/conventions/deployment-knowledge.md)).

> Status: draft — awaiting hardware-validation gate + operator go/no-go before execution.
> **Destructive.** This re-images the running ops-hub VM. Read the whole runbook,
> snapshot first, and do not run the cutover until steps 1–4 of the checklist are green.

## Purpose

One-time re-image of the ops-hub onto the smooth-upgrade-capable disk image, so that
**every future ops-hub boot-image upgrade is in-place** (agent-driven `upgrade_boot_image`
+ A/B systemd-boot rollback, Inc 1–4) rather than a re-provision. The ops-hub's *current*
agent predates Inc 2, so it cannot self-upgrade — this manual first hop is the bridge;
after it, the ops-hub upgrades in place, driven by an operator on the node (see
[After the first hop](#after-the-first-hop)), never by the fleet reconciler.

## Target parameters

Fill these in at execution time. The hub's VM and node/instance ids are in platform knowledge
(`tag:deployment-ops-hub`); the image fields come from the promoted `DiskImagePublication` for
the hub's node platform.

| Field | Value |
|---|---|
| NodeInstance | `<ops-hub-instance-id>` (`<ops-hub-instance-name>`) |
| Node | `<ops-hub-node-id>` |
| Proxmox VM | **`<pve-host>/qemu/<hub-vmid>`** (host `<pve-host>`, vmid `<hub-vmid>`) |
| Arch | amd64 |
| Target image | `<gitea-host>/powernode/disk-images/ubuntu-24.04-amd64-uefi:<target-git-sha>` |
| Target git_sha | `<target-git-sha>` |
| Target sha256 | `<target-sha256>` |
| Publication | `<publication-id>` |
| Platform URL | `https://<ops-hub-host>` |

## Pre-cutover checklist (ALL must be green before touching VM `<hub-vmid>`)

1. **Hardware-validation gate passed** — the A/B systemd-boot flow (`set-oneshot` → fail
   → auto-revert; `set-oneshot` → healthy → self-bless → `set-default` persists across
   reboots) validated on real UEFI/OVMF. Inc 3 recorded this as mandatory; it cannot be
   exercised in CI. **This runbook must not run until this is confirmed.**
2. **Image promoted** — `<target-git-sha>` set as the amd64 platform default
   (`platform_system_set_default_disk_image_publication`). Promoting also arms the Inc 4
   require-approval drift rollout for other amd64 nodes — expect approval requests; that
   is expected, not a fault.
3. **Cosign public key configured** — `POWERNODE_COSIGN_PUBLIC_KEY` (or `_FILE`) set on
   the platform. `UpgradeDispatcher.platform_blocker` fails closed without it; required
   for the ops-hub's *future* in-place upgrades (not for this re-image itself).
4. **Proxmox protection flag cleared** — `qm set <hub-vmid> --protection 0` on `<pve-host>` (protected
   VMs refuse stop/terminate; see the PVE-protection learning). Re-enable after cutover.

## Path A — preserve /persist (RECOMMENDED)

The campaign is `/persist`-preserving. VM `<hub-vmid>`'s `/persist` holds the agent's enrolled
mTLS cert + node state. If `/persist` survives the re-image, the new agent **reuses the
cert and reconnects as the same instance — no re-enrollment, no fw-cfg, no bootstrap
token**. This is the manual equivalent of the in-place `upgrade_boot_image` the ops-hub
will do on its own from now on.

> **Topology to confirm before executing (operator):** these images are UEFI UKI nodes —
> ESP (FAT, the UKI/boot manager) + a separate `/persist` (ext4) partition. Path A rewrites
> **only the ESP/boot** and leaves `/persist` untouched. Confirm VM `<hub-vmid>`'s disk actually
> has a separate `/persist` partition (not a single rootfs) before choosing Path A; if the
> rootfs is not fully self-contained in the UKI, fall to Path B.

1. **Snapshot** VM `<hub-vmid>` for rollback: `qm snapshot <hub-vmid> pre-<target-git-sha> --description "pre boot-image re-image 019f505f"`.
2. **Drain / quiesce** any ops-hub workloads you don't want interrupted (this reboots the node).
3. **Stop** the VM: `qm stop <hub-vmid>` (graceful; do **not** use `qm reset`).
4. **Attach the new image** as a scratch disk on `<pve-host>` (pull the OCI image to a local
   `.img`, e.g. via `skopeo copy` + the publication's `oci_ref`, verifying `sha256 =
   <target-sha256>`), then **copy only the ESP** contents (`/EFI/BOOT/BOOTX64.EFI` = systemd-boot
   manager + `/EFI/Linux/<uki>` = the boot-counted UKI slot) onto VM `<hub-vmid>`'s existing ESP,
   leaving the `/persist` partition intact. This converts VM `<hub-vmid>` to the new A/B layout in
   one shot while preserving state.
5. **Start**: `qm start <hub-vmid>`.
6. Proceed to **Verification**.

## Path B — fresh identity via fw-cfg (FALLBACK: /persist wiped / clean slate)

Use only if `/persist` is corrupt or a clean re-provision is wanted. This wipes node
state; the agent re-enrolls from injected identity.

Inject identity via QEMU fw-cfg (Proxmox VMs get **no** identity from a bare provision —
the 257a gap — and read it from `/sys/firmware/qemu_fw_cfg/by_name/opt/com.powernode/…`,
**not** cidata). The agent's `FwCfgStrategy` (`agent/internal/identity/fwcfg.go`) reads:

| fw-cfg key (`opt/com.powernode/…`) | Required | Value |
|---|---|---|
| `instance_uuid/raw` | **yes** (else `ErrNotFound`) | `<ops-hub-instance-id>` |
| `platform_url/raw` | for enroll | `https://<dev-host>` |
| `ca_pem/raw` | for enroll | **the Let's Encrypt chain** (must be the LE chain, not a leaf) |
| `bootstrap_token/raw` | for enroll | **single-use token minted by the platform** — see secret note |

> **Secret handling.** The `bootstrap_token` is a credential. Obtain it from the platform
> over TLS (re-provision / claim flow for instance `<ops-hub-instance-id>`); write it **only** into the
> fw-cfg file on `<pve-host>`. **Never** echo it, put it in shell history, commit it, or paste it
> into logs/this doc. Delete the seed file after `qm start`.

1. `qm snapshot <hub-vmid> pre-<target-git-sha> …` (rollback).
2. `qm stop <hub-vmid>`.
3. Write the full `<target-git-sha>` image to VM `<hub-vmid>`'s boot disk (verify `sha256`).
4. Build the CloudSeed fw-cfg files (one file per key above) and attach them:
   `qm set <hub-vmid> --args "-fw_cfg name=opt/com.powernode/instance_uuid/raw,file=…/instance_uuid \
   -fw_cfg name=opt/com.powernode/platform_url/raw,file=…/platform_url \
   -fw_cfg name=opt/com.powernode/ca_pem/raw,file=…/ca_pem \
   -fw_cfg name=opt/com.powernode/bootstrap_token/raw,file=…/bootstrap_token"`.
5. **`qm stop <hub-vmid>` then `qm start <hub-vmid>`** — a full stop/start so the new `--args` take
   effect. Do **not** `qm reset` (reset does not re-read `--args`).
6. Proceed to **Verification**.

## Verification (both paths)

- **Enroll/reconnect:** `platform_system_get_instance <ops-hub-instance-id>` — `status=running`, a fresh
  `last_heartbeat_at`, and (Path A) the **same** `mtls_subject`.
- **Boot-image identity (the whole point):** the heartbeat's `booted_image_git_sha ==
  <target-git-sha>`. Confirm via the NodeInstance serializer /
  `platform_system_drift_report` — the ops-hub must **no longer be drifted**.
- **/persist preserved (Path A):** ops-hub state/services intact; no re-enroll occurred.
- **A/B slot healthy:** after the first healthy heartbeat the agent self-blesses the new
  slot and `set-default`s it; a subsequent reboot stays on `<target-git-sha>` (not a fallback).
- **Services up:** ops-hub role services (SDWAN/egress via nftables, etc.) reconcile and
  start; `nft` present in the pivoted rootfs.

## Rollback

If the node fails to boot, enroll, or the new slot doesn't bless:
- **Path A / B:** `qm stop <hub-vmid> && qm rollback <hub-vmid> pre-<target-git-sha> && qm start <hub-vmid>` — restores
  the pre-cutover VM exactly (old image + `/persist`).
- A/B nodes also self-recover: a UKI that fails to boot exhausts its boot counter and
  systemd-boot falls back to the prior good slot automatically (no manual action) — but the
  snapshot is the authoritative rollback for this first-hop where the *old* layout was
  single-slot.
- Re-set `qm set <hub-vmid> --protection 1` once resolved.

## After the first hop

The ops-hub now runs an Inc-1–4 image. All subsequent boot-image upgrades are **in-place**
(agent-side UKI upgrade, cosign verification, A/B rollback, `/persist` preserved), but the
platform will NOT dispatch them to this node. Once `self_hosting_node_id` names the ops-hub
node (INV-1: no self-management):

- a direct `upgrade_boot_image` is refused by `System::BootImage::UpgradeDispatcher` before
  anything is queued ("it is this control plane's own hosting node");
- the boot-image drift rollout lists the node under `self_managed_excluded` and skips it.

The upgrade is an **operator action on the node itself**, with the same agent code the
dispatched task runs (`bootupgrade.Apply`):

1. **Collect the pins** from the promoted `DiskImagePublication` of the ops-hub's node
   platform (the one whose `git_sha` equals the platform's `disk_image_git_sha`), read on
   the control plane: `git_sha`, `uki_sha256`, and `uki_cosign_bundle` (stored
   base64-encoded). The cosign public key is the platform's `POWERNODE_COSIGN_PUBLIC_KEY`
   (or the file `POWERNODE_COSIGN_PUBLIC_KEY_FILE` names). Treat these as you would any
   signing material: public key and signature bundle only, never a private key.
2. **On the ops-hub, as root**, write the key and the DECODED bundle to files (the CLI
   base64-encodes the bundle file itself, so pass it raw):

   ```bash
   echo '<uki_cosign_bundle>' | base64 -d > /root/uki.bundle
   cat > /root/cosign.pub   # paste the public key, then Ctrl-D
   powernode-agent upgrade-boot-image \
     --target-git-sha <git_sha> \
     --uki-sha256 <uki_sha256> \
     --cosign-public-key-file /root/cosign.pub \
     --cosign-bundle-file /root/uki.bundle \
     --reboot
   ```

   `--target-git-sha` is not informational: the post-reboot confirm compares the booted
   sha against it, and a wrong value abandons the upgrade (silent revert at the next
   reboot). The UKI is pulled from `/api/v1/system/node_api/boot_image/download`, scoped
   to the node's own platform, and sha256- plus cosign-verified before anything is written.
   Without `--reboot` it writes and arms the slot but stays on the current image.
3. **Rollback is automatic.** The new UKI goes to the INACTIVE A/B slot and is armed as a
   one-shot next boot. It is blessed only when that boot reaches a healthy agent
   heartbeat; if it does not, the one-shot is consumed and the next boot falls through to
   the still-default old slot. Allow for the Rails 502 window (~30s) after the reboot.
4. **Verify** the node's `booted_image_git_sha` reads `<git_sha>` and the services are
   active, discovering the unit names rather than guessing them
   (`systemctl list-units 'powernode-*' --no-pager`).

Inc 5 is a one-time bridge, not a recurring procedure.

_Draft prepared 2026-07-11. Verify VM/partition specifics on `<pve-host>` before executing._
