# Fleet Imaging — Generic Image + Claim-by-ID

> Status: active

Provision many physical devices from **one** generic disk image plus a tiny
per-device config file. Image every card identically, drop a per-device
`identity.cfg`, install — each device enrolls as the instance you assigned it.

## Audience & prerequisites
- Operators bringing up more than a handful of physical nodes (SD cards, USB, NVMe).
- Permissions: `system.instances.create` + `system.instances.read`.
- A published generic image for the device architecture (amd64 UEFI / arm64 UEFI) —
  produced by the disk-image CI (see [`disk-image-ci.md`](./disk-image-ci.md)).
- Devices that UEFI-boot from the flashed media.

## Why this exists
Baking identity into each image means N image builds. Instead: **one** generic image
reusable across the whole fleet, and a ~5-line `identity.cfg` that differs per device.

## How it works (the claim-by-ID flow)
1. The generic image carries the kernel+initramfs (a UKI) on a FAT partition labelled
   `BOOT`, and trusts public TLS roots. It has **no identity**.
2. You pre-create one **physical NodeInstance** per device and download its
   `identity.cfg` — just `SERVER=<platform>` + `ID=<instance-uuid>`. No secret.
3. First boot: the agent mounts `BOOT` at `/boot`, reads `/boot/identity.cfg`, and
   polls `…/node_api/claim` with the baked-in `ID` plus its MAC/DMI.
4. The platform matches the **claimable** instance (physical, `pending`, unclaimed),
   auto-confirms it, and returns a single-use bootstrap token **over TLS** — which the
   device uses to enroll (mTLS). No per-device confirmation in the UI.

**Security model.** The config is secret-free: the `ID` is a one-time *binding
capability* gated by the instance's claimable state. The bootstrap token is delivered
only to the device over TLS by the claim poll — never written to the file. Binding is
**single-use**: once a device claims an instance, its boot config is no longer issued
(HTTP 409), so a leaked `ID` can't hijack an already-provisioned device.

## Procedure
1. **Download the generic image** — Platforms → your architecture → *Download image*
   (one file for the whole fleet).
2. **Flash every card** identically (`dd`, Raspberry Pi Imager, etc.).
3. **Pre-create the NodeInstances** — one physical instance per device, left `pending`.
   Name them so you can match instance ↔ hardware.
4. **Download each boot config** — instance → *Download boot config* →
   `identity-<name>.cfg`.
   API: `GET /api/v1/system/nodes/:node_id/node_instances/:id/boot_config`.
5. **Drop the config onto the card** — mount the `BOOT` (FAT) partition and copy the
   file as `identity.cfg`. Private-CA platforms: also copy the CA as
   `powernode-ca.pem` and uncomment `CA_PEM_FILE` in the config.
6. **Install + power on** — the device claims by ID and enrolls automatically.

## Verify
- The NodeInstance leaves `pending` and shows a claim code + discovered MAC.
- The device's agent reports in (heartbeat / running modules).
- Re-downloading a claimed instance's boot config returns **409** — expected, the
  single-bind guard.

## Troubleshooting
- **Device keeps polling, never claims:** confirm the instance is still `pending`
  (claimable) and the `ID` in `identity.cfg` matches. A claimed/terminated instance
  won't match — its boot config download also returns 409.
  > **The operator must bind the claim.** The agent's claim poll
  > (`agent/internal/boot/boot.go`) defaults to an **infinite** `ClaimPollTimeout`
  > — a device that never matches a claimable instance will poll on
  > `ClaimPollInterval` (30 s) forever rather than fail fast. There is no
  > self-service binding: you must pre-create the physical NodeInstance (Procedure
  > step 3) so the `ID` has a claimable target. (A finite default — 10 min — is
  > proposed but not yet shipped, so today the burden is on the operator to bind.)
- **TLS errors on the device:** the platform's serving cert must be trusted by the
  image. Public/Let's-Encrypt certs work out of the box; for a private CA, drop
  `powernode-ca.pem` and set `CA_PEM_FILE=/boot/powernode-ca.pem`.
- **Wrong `SERVER`:** it comes from the platform's `POWERNODE_PLATFORM_URL` and must be
  reachable + cert-valid *from the device's network*, not just from your workstation.

## See also
- [`node-provisioning.md`](./node-provisioning.md) — full single-node lifecycle + per-state recovery.
- [`federation-setup.md`](./federation-setup.md) — multi-site federation (managed children).
- [`disk-image-ci.md`](./disk-image-ci.md) — how the generic images are built + published.

_Last verified: 2026-06-03_
