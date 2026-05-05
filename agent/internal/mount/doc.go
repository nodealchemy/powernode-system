// Package mount orchestrates the union root that NodeInstances boot into:
// composefs lower layer + tmpfs (or /persist) overlay, mounted at /sysroot
// for switch_root.
//
// Implements the Golden Eclipse plan's "verified mount" path: each module's
// rootfs is published as a composefs (read-only, fs-verity-checked) layer;
// the union mount stacks them in priority order and adds a writable upper
// layer for runtime changes.
//
// # Layout
//
//	/sysroot/                           ← target for switch_root
//	  ├── (composefs lower 1)           ← system-base
//	  ├── (composefs lower 2)           ← security-hardening
//	  ├── (composefs lower N)           ← higher-priority modules
//	  └── (overlayfs upper)             ← tmpfs (ephemeral) or /persist
//
// # Key types
//
//   Layout          — { LowerLayers, UpperLayer, WorkLayer, Target }
//   Composefs       — wraps mkcomposefs + composefs-info verification
//   Overlayfs       — assembles the union mount via mount(2) syscall
//   BindHelper      — bind-mounts /dev, /proc, /sys, /run from initramfs
//
// Used by the `prepare-root` subcommand during initramfs init-bottom; runs
// before switch_root.
//
// Server-side counterpart: module composition is platform-driven; see the
// extensions/system/server/app/services/system/module_oci_ingest_service.rb
// for the artifact-side digest verification.
package mount
