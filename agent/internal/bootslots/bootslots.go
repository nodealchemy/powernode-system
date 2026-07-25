// Package bootslots tracks the A/B boot-image slots for systemd-boot
// boot-counting auto-rollback (campaign 019f505f increment 3).
//
// The ESP carries two UKI entries under /EFI/Linux: powernode-a.efi and
// powernode-b.efi. The image ships booting slot A. An in-place upgrade writes
// the target UKI to the INACTIVE slot with a systemd-boot boot-counter suffix
// (powernode-<slot>+<tries>.efi), sets it as the one-shot next boot, and
// reboots. If the new UKI boots and the agent confirms health (first successful
// heartbeat → `systemd-bless-boot good`), systemd-boot strips the counter and
// the slot becomes permanently good; if it fails to boot `tries` times it is
// marked bad and systemd-boot falls back to the other (good) slot — automatic
// rollback, no brick.
//
// Which slot is active is tracked in a small /persist state file rather than by
// parsing the LoaderEntrySelected UTF-16 EFI variable: /persist survives the
// reboot, the state only advances when a new slot is CONFIRMED healthy, and it
// keeps the whole A/B decision testable off-hardware.
package bootslots

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

const (
	// SlotA / SlotB are the two slot identifiers.
	SlotA = "a"
	SlotB = "b"
	// EntryPrefix is the /EFI/Linux basename prefix for a slot's UKI.
	EntryPrefix = "powernode-"
	// DefaultStatePath is the /persist-backed slot-state file.
	DefaultStatePath = "/persist/var/lib/powernode/boot-slot.json"
)

// State is the persisted A/B slot state.
type State struct {
	// Active is the slot the node is currently running from (default "a").
	Active string `json:"active"`
	// Pending is the slot a not-yet-confirmed upgrade was written to (""
	// when no upgrade is in flight), and PendingSHA the target it carries.
	Pending    string `json:"pending,omitempty"`
	PendingSHA string `json:"pending_sha,omitempty"`
}

// Other returns the opposite slot.
func Other(slot string) string {
	if slot == SlotB {
		return SlotA
	}
	return SlotB
}

// EntryBase is a slot's /EFI/Linux filename stem, without the ".efi" suffix or
// any boot-counter (e.g. "powernode-a"). Used to glob a slot's whole file family.
func EntryBase(slot string) string { return EntryPrefix + slot }

// EntryName returns the /EFI/Linux basename for a slot. With tries > 0 it
// carries the systemd-boot boot-counter suffix (powernode-a+3.efi); with
// tries <= 0 it is the permanent-good name (powernode-a.efi).
func EntryName(slot string, tries int) string {
	if tries > 0 {
		return fmt.Sprintf("%s+%d.efi", EntryBase(slot), tries)
	}
	return EntryBase(slot) + ".efi"
}

// loaderGUID is the systemd-boot Boot Loader Interface vendor GUID, as defined
// by the systemd Boot Loader Interface specification. It MUST match the GUID
// systemd-boot actually stamps onto its EFI variables — a wrong value makes
// BootedViaSystemdBoot() return false on every node, which silently disables
// the entire A/B boot-counter rollback path and routes every upgrade into the
// single-slot bootloader-overwrite fallback. TestLoaderGUIDMatchesSpec and
// TestBootedViaSystemdBootDetectsRealLoaderInfo pin this; do not "simplify"
// them away.
const loaderGUID = "4a67b082-0a4c-41cf-b6c7-440b29bb8c4f"

// efivarsDir is the EFI variable store mount point. A variable (not a const) so
// tests can point it at a temp dir and exercise the detection for real instead
// of trusting the constant by inspection.
var efivarsDir = "/sys/firmware/efi/efivars"

// SetEfivarsDirForTest points the EFI variable store at dir and returns a
// restore func. Exported ONLY so packages layered on BootedViaSystemdBoot (i.e.
// bootupgrade) can test the branch that hangs off it — without a seam, Apply's
// refusal path is untestable and a regression re-adding a bootloader-overwriting
// fallback would pass every test in the repo. Production code must never call
// this; nothing outside _test.go does.
func SetEfivarsDirForTest(dir string) (restore func()) {
	prev := efivarsDir
	efivarsDir = dir
	return func() { efivarsDir = prev }
}

// EfivarsAvailable reports whether the EFI variable store is readable at all.
// Used to tell "this node has no A/B layout" apart from "we cannot SEE the EFI
// variables" (efivarfs not mounted in our namespace) — both make
// BootedViaSystemdBoot false, but they need different operator remedies.
func EfivarsAvailable() bool {
	fi, err := os.Stat(efivarsDir)
	return err == nil && fi.IsDir()
}

// BootedViaSystemdBoot reports whether the CURRENT boot went through systemd-boot
// (it exports LoaderInfo into the EFI variable store). Nodes whose ESP predates
// the A/B layout boot the bare UKI directly from the firmware and have no such
// variable — the upgrade path refuses to write for them rather than writing
// /EFI/Linux slots the firmware will never read.
func BootedViaSystemdBoot() bool {
	_, err := os.Stat(filepath.Join(efivarsDir, "LoaderInfo-"+loaderGUID))
	return err == nil
}

// Load reads the slot state, defaulting to {Active: "a"} when absent/unreadable
// (a fresh image booting slot A).
func Load() State { return LoadFrom(DefaultStatePath) }

// LoadFrom is Load with an explicit path (for tests).
func LoadFrom(path string) State {
	s := State{Active: SlotA}
	b, err := os.ReadFile(path)
	if err != nil {
		return s
	}
	var loaded State
	if json.Unmarshal(b, &loaded) == nil && (loaded.Active == SlotA || loaded.Active == SlotB) {
		return loaded
	}
	return s
}

// Save persists the state atomically.
func (s State) Save() error { return s.SaveTo(DefaultStatePath) }

// SaveTo is Save with an explicit path (for tests).
func (s State) SaveTo(path string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	b, err := json.Marshal(s)
	if err != nil {
		return err
	}
	tmp := path + ".new"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
