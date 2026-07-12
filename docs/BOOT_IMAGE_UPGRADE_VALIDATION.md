# Boot-Image In-Place Upgrade — Validation Log

Campaign `019f505f` (smooth boot-image upgrades). Field-validation record for the
in-place, `/persist`-preserving, A/B-rollback upgrade path.

## 2026-07-12 — hardware bootstrap (Inc 5)

- ops-hub instance `019f5463` (VM `dna/qemu/102`, OVMF) re-provisioned onto image
  `34f2af6d` (`019f5329`): A/B systemd-boot booted on real hardware, nf_tables
  fix confirmed (11/11 modules attached), `booted_image_git_sha` reported, drift
  sensor = no drift. Cosign public key + standalone UKI plumbing wired and verified
  (`POWERNODE_COSIGN_PUBLIC_KEY_FILE`, `uki_oci_ref`/`uki_sha256`/`uki_cosign_bundle`).

## In-place upgrade validation (this bump)

This doc-only commit exists to mint a fresh image `git_sha` that differs from the
one the hub is running, so the operator-triggered `system_upgrade_boot_image`
path can be exercised end-to-end: pull UKI → cosign-verify → write inactive A/B
slot → reboot → bless (or fail → auto-revert) — with **no re-provision** and the
enrolled `/persist` cert reused. Results appended below once observed.
