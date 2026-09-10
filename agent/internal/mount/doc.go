// Package mount implements the agent's on-node read-only filesystem +
// overlayfs union machinery, and the storage-volume mounts that hang off it.
//
// Each platform module is published as a single erofs image (Enhanced
// Read-Only File System) and loop-mounted at attach time; the union of all
// attached modules forms /sysroot via overlayfs, in priority order, with a
// tmpfs (or /persist) upper layer and a /var bind mount onto /persist/var.
// Used by the `prepare-root` subcommand during initramfs init-bottom, before
// switch_root.
//
// # Layout
//
//	/sysroot/                           ← target for switch_root
//	  ├── (erofs lower 1)               ← system-base
//	  ├── (erofs lower 2)               ← security-hardening
//	  ├── (erofs lower N)               ← higher-priority modules
//	  └── (overlayfs upper)             ← tmpfs (ephemeral) or /persist
//
// # Key types
//
//	Layout               — resolved paths for one node's union root
//	Module / ModuleStack — an attachable erofs image and the priority-ordered
//	                       stack of them
//	Overlay              — the assembled overlayfs union
//	State                — attachment state persisted across agent restarts
//	StorageVolumeBinding — a platform-assigned volume (NFSDetails,
//	                       SMBDetails, ISCSIDetails) to mount on this node
//	Runner               — the side-effecting seam (mount, umount, mkdir);
//	                       ExecRunner in production, RecorderRunner in tests,
//	                       which records each Invocation for assertion
//
// The erofs and overlayfs work is done by functions over Runner, not by
// dedicated Erofs / Overlayfs / BindHelper objects — see erofs.go, overlay.go
// and bind.go.
//
// # Why erofs
//
//   - In Linux mainline since 5.4 (Nov 2019). Every distro we'd target ships
//     it enabled: Ubuntu 20.04+, Debian 11+, Rocky/Alma 9+, Fedora 36+,
//     Amazon Linux 2023, Alpine. No kernel-build choice to negotiate the way
//     composefs did.
//   - Production-proven on Android (default /system FS since 11), ChromeOS
//     and Steam Deck.
//   - Native fs-verity integration, faster random-access reads than squashfs,
//     tail-packing + chunked layout deduplicate identical content within one
//     image.
//
// The earlier dual-format machinery (composefs + squashfs) was removed when we
// converged on erofs as the single canonical format. See
// powernode.composefs_ubuntu_kernel_gap in MCP memory for the decision context.
//
// Artifacts are fetched and verified by internal/oci (through the platform,
// NOT a registry — see that package's doc) and cosign + fs-verity checked
// before anything here mounts them.
//
// Reference: Golden Eclipse plan M2.D + Security Architecture (erofs fs-verity
// at file open + capability dropping); legacy ipn_functions ipn_mod_attach +
// ipn_mod_detach (which used aufs branch ops).
package mount
