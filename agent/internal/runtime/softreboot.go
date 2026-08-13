package runtime

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"strings"

	"github.com/nodealchemy/powernode-system/agent/internal/bootslots"
	"github.com/nodealchemy/powernode-system/agent/internal/lifecycle"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// This file is the middle rung of the recompose ladder:
//
//	hot materialize   — hotreconcile/hotprune/hotleaver; per-module service
//	                    impact only; refused for reboot_required modules and
//	                    scratch-budget breaches
//	SOFT-REBOOT       — this file: compose the desired set at /run/nextroot,
//	                    `systemctl soft-reboot` into it; userspace-only
//	                    restart (seconds), same kernel, no bootloader, no
//	                    initramfs, no re-enrollment
//	full reboot       — the A/B boot-image path, unchanged
//
// The soft-reboot tier exists for exactly the changes the hot tier refuses:
// reboot_required layers (base-os) and materializations too large for the
// scratch tmpfs. The union is composed by the SAME ComposeForPivot the cold
// boot path uses — at mount.NextrootLayout's sysroot with its own scratch —
// so what soft-reboot switches into is bit-for-bit what a cold boot would
// have composed.
//
// LKG interplay: a soft-reboot does not change the kernel boot ID, so the
// LKG capturer's stale-breadcrumb check cannot distinguish "prepared and
// executed" from "prepared and abandoned". The prepare path therefore
// captures the breadcrumb via ReconcilerConfig.BreadcrumbSink instead of
// letting ComposeForPivot write it; the CLI commits it to disk only at
// execute time, immediately before invoking soft-reboot. A/B slot state is
// untouched — preflight refuses while an unproven slot upgrade is armed.

// MinSoftRebootSystemd is the first systemd release shipping
// `systemctl soft-reboot` (v254; the noble base image carries 255+).
const MinSoftRebootSystemd = 254

// CriticalSoftRebootMounts are mounts whose disappearance across a
// soft-reboot leaves the node unrecoverable, so the preflight refuses
// unless each is configured to survive.
//
// /persist carries the enrolled mTLS PKI, the boot LKG + pending-compose
// state, the module blob cache, and the durable /var bind. A node that
// soft-reboots without it comes up with no identity and no durable state
// — and on a self-hosted control plane it cannot re-enroll, because the
// platform it would enroll against is the node itself.
//
// WHY THIS IS /persist AND NOT run-nextroot-persist.mount. prepareNextrootMounts
// notes that /persist reaches the new root SOLELY via that bind, which reads like
// an argument for checking the bind instead. It is not, and the reasoning that it
// would be rested on a premise that is FALSE. Measured on a scratch VM (systemd
// 255, 2026-08-11), two soft-reboots with /persist on a loop device and a
// non-recursive bind at /run/nextroot/persist:
//
//	stock persist.mount (DefaultDependencies=yes, Conflicts=umount.target):
//	  "Unmounting persist.mount" -> the ext4 superblock is released -> the CARRIER
//	  goes with it ("run-nextroot-persist.mount: Deactivated successfully", with no
//	  Unmounting line of its own). /persist absent afterwards. The claim that a bind
//	  survives its source being unmounted, so tearing down persist.mount is
//	  harmless, does not hold here.
//	persist.mount + DefaultDependencies=no drop-in:
//	  both /persist and the carrier survive; the marker file is readable afterwards.
//
// So the carrier's fate FOLLOWS persist.mount's in both directions, which makes
// /persist the correct thing to check HERE. Do not "fix" this list to the bind;
// TestCriticalSoftRebootMounts_IsPersistNotTheNextrootCarrier fails if you do —
// but note carefully what that test does and does not say (its rationale was
// corrected 2026-08-13, IMP-e4f3b8002de6). The carrier is not unguarded and is not
// unguardable. The reason it cannot be checked from THIS list is timing: it does
// not exist when SoftRecomposePreflight runs, so its unit reads LoadState=not-found
// and the guard would refuse on every node forever. It is checked by
// NextrootSurvivalGate instead, after ComposeForPivot has made it real.
//
// Both runs above measured the carrier at DefaultDependencies=yes, including the
// run where /persist survived. That is a fact about a unit with NO DROP-IN — those
// runs shipped none for it — and not evidence that one cannot be applied. A drop-in
// for it now ships in powernode-system-base, on the same mechanism that is verified
// live for persist.mount (a mountinfo-synthesized unit with no fragment still takes
// drop-ins). Whether it resolves as intended on a pivot node is unmeasured; the gate
// fails closed if it does not.
//
// Bound on the evidence: the scratch VM's /run/nextroot was a bind of /, and no
// switch-root line appeared in the journal, so this measures the umount.target
// survival semantics — the open question — and not a full root swap.
//
// THE APPARENT CONTRADICTION, RESOLVED. The scratch VM reported an EMPTY
// Conflicts for its mounts under /run, while the live pivot node reports
// Conflicts=umount.target for run-powernode-scratch.mount and all 14
// run-powernode-modules-*.mount units. Both readings are accurate: they are
// different mounts on different systems (plain binds of / and of a loop mount
// there; tmpfs and erofs here). It does kill the tempting shortcut "mounts under
// /run are exempt" — run-powernode-scratch.mount is itself under /run and DOES
// carry the conflict. The actual discriminator is not established and must not be
// assumed. This is why NextrootSurvivalGate probes each unit rather than
// reasoning from its path.
//
// WHAT THIS LIST IS NOT. It is the list the PREFLIGHT can check — mounts that
// already exist before anything is composed. The mounts that carry the soft-reboot
// itself (/run/nextroot and its binds) do not exist yet at preflight time; they are
// checked by NextrootSurvivalGate, after ComposeForPivot creates them.
var CriticalSoftRebootMounts = []string{"/persist"}

// NextrootSurvivalGate is the SECOND mount-survival gate, and it exists
// because the first one structurally cannot cover the mounts that matter
// most.
//
// WHY A SECOND GATE, AND NOT MORE ENTRIES IN CriticalSoftRebootMounts.
// SoftRecomposePreflight runs BEFORE ComposeForPivot, so at that moment
// /run/nextroot and its binds do not exist. `systemctl show` reports
// LoadState=not-found for them, mountSurvivesSoftReboot's unknown-unit clause
// correctly reads that as unproven, and the preflight would refuse on every
// node forever — disabling the tier rather than guarding it. The check has to
// happen after the mounts are real, which is here.
//
// THE TWO LETHAL MOUNTS. Both are checked as hard refusals:
//
//	/run/nextroot                  the composed union itself. systemd-soft-reboot
//	                               switches into it only if it still finds an OS
//	                               tree there; torn down at umount.target, PID1's
//	                               probe fails and the switch SILENTLY does not
//	                               happen. The caller had already committed a boot
//	                               breadcrumb asserting that it did, so the node
//	                               comes up on the old set while its own on-disk
//	                               record claims the new one. Refusing here is what
//	                               keeps that breadcrumb honest — see the gate's
//	                               placement in soft_recompose.go, BEFORE the write.
//	<sysroot>/persist              the sole carrier of /persist into the new root
//	                               after the /run-bind fix (prepareNextrootMounts).
//	                               persist.mount's DefaultDependencies=no drop-in
//	                               does NOT reach it: a per-unit drop-in extends one
//	                               unit, and this is a separate, mountinfo-generated
//	                               one. Losing it lands in the new root unable to
//	                               resolve anything under /persist — the enrolled
//	                               PKI and the boot LKG among them. (Note the
//	                               mechanism: these are reached by absolute
//	                               /persist/var/... paths. /var itself is NOT a
//	                               bind mount on a current node —
//	                               mount.EnsurePersistentVar has no production
//	                               caller — so "the durable /var bind" as written
//	                               elsewhere in this tree describes an unused code
//	                               path, not how the node works today.)
//
// The caller passes the destinations prepareNextrootMounts ACTUALLY established
// rather than a re-derivation of the source list, so adding a bind source cannot
// quietly add an unchecked carrier.
//
// KNOWN LIMIT — RECURSIVE SUBMOUNTS. Each bind destination is checked as ONE unit.
// prepareNextrootMounts uses `mount --rbind`, so if a bind source ever acquires
// child mounts, the rbind reproduces them as separate generated units beneath the
// destination, each with its own survival properties, and this gate would not see
// them. That is latent rather than live: /persist has no child mounts (verified on
// a pivot node 2026-08-13, zero entries under /persist in /proc/self/mountinfo),
// and it is the only bind source. Mounting anything under /persist — a storage
// volume, a separate durable /var — makes this real, and the gate must then walk
// the mount table beneath each destination instead of probing one unit.
//
// WHY THE LAYER MOUNTS ARE REPORTED, NOT REFUSED — AND WHY THAT IS NOT A CLAIM
// THAT THEY ARE SAFE. The union's erofs lowerdirs and its scratch upperdir also
// carry Conflicts=umount.target on a live node (15 units measured 2026-08-11).
// Whether losing them matters is GENUINELY UNSETTLED, and this repo contains both
// answers:
//
//	live-recompose-design-2026-08-06.md §7b (docs/operations/ in the PARENT
//	  platform repo, not this one) — "a composed overlay keeps serving after its
//	  lower and upper mountpoints are unmounted (overlayfs clones its layers
//	  privately)". Recorded there as an aside, with no measurement attached. That
//	  would make layer teardown a non-event.
//	mount/union_lowers.go (2026-08-07, LIVE PIVOT NODE) — the opposite: unmounting
//	  a module whose path the live union still listed "rips that layer's files out
//	  of the running root", observed as the entire Go toolchain vanishing from /.
//
// The second is the production-shaped measurement (erofs lowers, pivot node,
// exactly this mount type), so do NOT read the advisory classification as a safety
// finding. It is not one.
//
// They are nonetheless not refused, for a reason that does not depend on which
// answer is right: a refusal here is unfixable and would delete the tier. Their
// unit names are digest- and generation-derived, so no static drop-in can cover
// them, and refusing on a condition no shipped file can satisfy is the same
// self-disabling guard this file already got wrong once. The guard bites where it
// can actually be remediated — the two stable mounts above — and the layer set is
// surfaced so an operator sees it rather than being told it is fine. Settling this
// needs a disposable pivot node (design doc §7b keeps --execute gated on real
// hardware until then); if teardown is proven to matter, the fix is a generated
// drop-in written at prepare time, not a refusal.
//
// Lowerdirs come from the LIVE mount table, not from the layout the composer was
// handed — the same discipline mount.LiveUnionLowerDirs exists to enforce.
//
// daemon-reload FIRST. The drop-ins that make the two lethal mounts survive ship in
// powernode-system-base and reach running nodes by hot-reconcile, and systemd does
// not see a new drop-in file until it rescans. Probing before the reload reads
// pre-delivery properties and refuses on a node that is correctly configured. A
// reload that fails leaves the drop-ins unproven, which this file treats as "do not
// proceed".
func NextrootSurvivalGate(ctx context.Context, run mount.Runner, layout mount.Layout, bindDests []string) ([]string, error) {
	if err := run.Run(ctx, "systemctl", "daemon-reload"); err != nil {
		return nil, fmt.Errorf("systemctl daemon-reload before probing nextroot mount survival: %w "+
			"(without a reload systemd may not have loaded the mount drop-ins, so their properties cannot be trusted)", err)
	}

	lethal := append([]string{layout.SysRoot}, bindDests...)
	for _, path := range lethal {
		if ok, why := mountSurvivesSoftReboot(ctx, run, path); !ok {
			return nil, fmt.Errorf("%s would not survive the soft-reboot (%s). "+
				"systemd tears down every mount except /run unless its unit sets DefaultDependencies=no and does not Conflicts=umount.target. "+
				"%s so soft-rebooting now would %s. "+
				"Ship the %s drop-in in powernode-system-base (and daemon-reload) before using --execute; a full reboot applies this composition safely in the meantime",
				path, why,
				lethalRole(path, layout.SysRoot),
				lethalConsequence(path, layout.SysRoot),
				MountUnitName(path))
		}
	}

	// Advisory: everything the union is built OUT of. Non-fatal by design —
	// see the doc comment.
	lowers, err := mount.LiveUnionLowerDirs(layout.SysRoot)
	if err != nil {
		return nil, fmt.Errorf("read the live mount table to enumerate %s's layers: %w "+
			"(the layer set is unknown, and unknown is not a state to soft-reboot from)", layout.SysRoot, err)
	}
	var doomed []string
	for _, path := range append(lowers, layout.ScratchRoot) {
		if ok, _ := mountSurvivesSoftReboot(ctx, run, path); !ok {
			doomed = append(doomed, path)
		}
	}
	return doomed, nil
}

// lethalRole and lethalConsequence keep the refusal specific about WHICH of
// the two failures the operator is looking at — they have different causes
// and different fixes, and a generic message would blur them.
func lethalRole(path, sysroot string) string {
	if path == sysroot {
		return "This is the composed union systemd would switch into,"
	}
	return "This is the sole carrier of a durable mount into the new root,"
}

func lethalConsequence(path, sysroot string) string {
	if path == sysroot {
		return "leave PID1 with no OS tree to switch into — the switch silently would NOT happen while the boot breadcrumb claims it did"
	}
	return fmt.Sprintf("land in the new root with %s GONE", strings.TrimPrefix(path, sysroot))
}

// mountSurvivesSoftReboot reports whether the mount unit backing path is
// configured to stay mounted through the shutdown phase of a soft-reboot.
//
// This is NOT the default. systemd-soft-reboot.service documents that
// "/run/ file system remains mounted", but that other mounts survive only
// if "configured to remain until the very end of the shutdown process" —
// i.e. DefaultDependencies=no and no Conflicts=umount.target. A stock
// fleet node's persist.mount has DefaultDependencies=yes AND
// Conflicts=umount.target (verified on a live pivot node 2026-08-07), so
// it is torn down like any other filesystem.
//
// A unit systemctl does not know (empty output) is reported as NOT
// surviving: unknown means unproven, and the failure mode here is losing
// the node.
func mountSurvivesSoftReboot(ctx context.Context, run mount.Runner, path string) (bool, string) {
	unit := MountUnitName(path)
	out, err := run.Output(ctx, "systemctl", "show", unit,
		"-p", "DefaultDependencies", "-p", "Conflicts", "-p", "LoadState")
	if err != nil {
		return false, fmt.Sprintf("could not query %s: %v", unit, err)
	}
	fields := map[string]string{}
	for _, line := range strings.Split(string(out), "\n") {
		k, v, ok := strings.Cut(strings.TrimSpace(line), "=")
		if ok {
			fields[k] = v
		}
	}
	if len(fields) == 0 || fields["LoadState"] == "not-found" {
		return false, fmt.Sprintf("%s is unknown to systemd — cannot prove it survives", unit)
	}
	var reasons []string
	if !strings.EqualFold(fields["DefaultDependencies"], "no") {
		reasons = append(reasons, "DefaultDependencies is not 'no'")
	}
	if strings.Contains(fields["Conflicts"], "umount.target") {
		reasons = append(reasons, "it Conflicts=umount.target")
	}
	if len(reasons) > 0 {
		return false, fmt.Sprintf("%s: %s", unit, strings.Join(reasons, " and "))
	}
	return true, ""
}

// MountUnitName renders a path as its systemd mount-unit name using
// systemd's own escaping ("/" -> "-", "-" -> "\x2d", other specials
// hex-escaped), so "/persist" -> "persist.mount".
func MountUnitName(path string) string {
	trimmed := strings.Trim(path, "/")
	if trimmed == "" {
		return "-.mount"
	}
	var b strings.Builder
	for i := 0; i < len(trimmed); i++ {
		c := trimmed[i]
		switch {
		case c == '/':
			b.WriteByte('-')
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9', c == '_':
			b.WriteByte(c)
		case c == '.' && i > 0:
			b.WriteByte(c)
		default:
			fmt.Fprintf(&b, `\x%02x`, c)
		}
	}
	return b.String() + ".mount"
}

// pendingBootSlot indirects bootslots.Load for tests.
var pendingBootSlot = func() string { return bootslots.Load().Pending }

// SystemdVersion parses `systemctl --version` ("systemd 255 (255.4-…)").
func SystemdVersion(ctx context.Context, run mount.Runner) (int, error) {
	out, err := run.Output(ctx, "systemctl", "--version")
	if err != nil {
		return 0, fmt.Errorf("systemctl --version: %w", err)
	}
	first := strings.SplitN(strings.TrimSpace(string(out)), "\n", 2)[0]
	fields := strings.Fields(first)
	if len(fields) < 2 || fields[0] != "systemd" {
		return 0, fmt.Errorf("unrecognized systemctl --version output %q", first)
	}
	v, aerr := strconv.Atoi(fields[1])
	if aerr != nil {
		return 0, fmt.Errorf("unrecognized systemd version %q: %w", fields[1], aerr)
	}
	return v, nil
}

// SoftRecomposePreflight verifies this node can soft-recompose at all.
// Refusals are errors so the CLI stops before composing anything.
func SoftRecomposePreflight(ctx context.Context, run mount.Runner) error {
	if pivotAwareRootMode() != lifecycle.RootModeNative {
		return errors.New("soft-recompose only applies to pivot-booted nodes — on this boot model the union is remounted live on every stack change, so there is nothing a soft-reboot would fix")
	}
	v, err := SystemdVersion(ctx, run)
	if err != nil {
		return fmt.Errorf("probe systemd version: %w", err)
	}
	if v < MinSoftRebootSystemd {
		return fmt.Errorf("systemd %d has no soft-reboot support (need >= %d)", v, MinSoftRebootSystemd)
	}
	if p := pendingBootSlot(); p != "" {
		return fmt.Errorf("an A/B boot-image upgrade is armed (pending slot %q, unproven) — a soft-reboot skips the bootloader, so it would neither boot the pending slot nor exercise the bless-or-rollback flow; let the upgrade resolve first", p)
	}
	for _, path := range CriticalSoftRebootMounts {
		if ok, why := mountSurvivesSoftReboot(ctx, run, path); !ok {
			return fmt.Errorf("%s is not configured to survive a soft-reboot (%s). "+
				"systemd tears down every mount except /run unless its unit sets DefaultDependencies=no and does not Conflicts=umount.target, "+
				"so soft-rebooting now would land in the new root with %s GONE — no enrolled PKI, no LKG, no durable /var. "+
				"Ship a mount drop-in that keeps it to the end of shutdown before using --execute; a full reboot applies the composition safely in the meantime",
				path, why, path)
		}
	}
	return nil
}
