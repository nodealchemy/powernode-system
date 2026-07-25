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
	"strings"
	"sync"
	"unicode/utf16"
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

// EfivarsAvailable reports whether the EFI variable store is actually readable —
// i.e. efivarfs is mounted here and exposing variables.
//
// It must NOT be an os.Stat/IsDir check. /sys/firmware/efi/efivars is a
// kernel-created sysfs directory: it is the mountpoint efivarfs mounts ONTO, so
// it pre-exists the mount and Stat succeeds on every UEFI node whether or not
// efivarfs is mounted. That would make this predicate always true and defeat the
// whole point of distinguishing "no A/B layout" from "cannot see EFI variables",
// sending an operator to reimage a node that is fine. Requiring at least one
// entry is what actually separates the two: an unmounted (or empty, e.g. EFI
// runtime services disabled) store yields nothing to read.
func EfivarsAvailable() bool {
	f, err := os.Open(efivarsDir)
	if err != nil {
		return false
	}
	defer f.Close()
	names, err := f.Readdirnames(1)
	return err == nil && len(names) > 0
}

// stateMu serializes read-modify-write cycles on the slot-state file. Two
// goroutines touch it concurrently in the live agent — the heartbeat loop
// (ConfirmBoot) and the task-lease loop (the upgrade handler) — and a lost
// update there can delete a freshly-written slot and strand the node with no
// retry. Load/Save alone cannot fix that; the whole cycle must be atomic, which
// is what Update provides.
var stateMu sync.Mutex

// Update runs fn against the persisted state under a lock and saves the result,
// making the load-modify-save cycle atomic against the other goroutine. fn may
// perform slow work (ESP mounts) — the critical sections here are short-lived
// relative to an upgrade, and correctness beats contention on a once-per-boot
// path. Returning an error from fn aborts WITHOUT saving.
func Update(fn func(*State) error) error {
	stateMu.Lock()
	defer stateMu.Unlock()
	before := Load()
	s := before
	if err := fn(&s); err != nil {
		return err
	}
	// Never write when nothing changed. An unconditional Save turned every
	// no-op confirm into a write on EVERY node on EVERY boot — including nodes
	// that have never upgraded — so a non-writable /persist produced a permanent
	// per-tick error on a node with no upgrade in flight at all. It also asserted
	// {"active":"a"} onto nodes whose state was legitimately absent, manufacturing
	// exactly the state-vs-ESP divergence SlotGoodExists exists to catch.
	if s == before {
		return nil
	}
	return s.Save()
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

// statePath is where Load/Save read and write. A variable so tests in dependent
// packages (bootupgrade's ConfirmBoot) can point it at a temp dir — without this
// the headline empty-sha / mismatch guards are untestable, and those are the two
// branches that must never delete the running slot's boot file.
var statePath = DefaultStatePath

// SetStatePathForTest points the slot-state file at path and returns a restore
// func. Test-only, like SetEfivarsDirForTest; production never calls it.
func SetStatePathForTest(path string) (restore func()) {
	prev := statePath
	statePath = path
	return func() { statePath = prev }
}

// BootedEntry returns the /EFI/Linux entry name systemd-boot actually selected
// for THIS boot, read from the LoaderEntrySelected EFI variable (UTF-16LE, after
// a 4-byte attribute prefix). Empty when unavailable.
//
// This is the authoritative answer to "which slot are we running?". Inferring it
// from a git_sha comparison cannot distinguish "rolled back" from "booted the new
// slot but the sha is wrong/unreadable" — and those need opposite handling, since
// one is a routine rollback and the other must never touch the ESP.
func BootedEntry() string {
	b, err := os.ReadFile(filepath.Join(efivarsDir, "LoaderEntrySelected-"+loaderGUID))
	if err != nil || len(b) <= 4 {
		return ""
	}
	u := make([]uint16, 0, (len(b)-4)/2)
	for i := 4; i+1 < len(b); i += 2 {
		u = append(u, uint16(b[i])|uint16(b[i+1])<<8)
	}
	return strings.TrimRight(string(utf16.Decode(u)), "\x00")
}

// BootedSlot maps BootedEntry onto "a"/"b", or "" when undeterminable. Handles
// boot-counter suffixes (powernode-b+2-1.efi) as well as blessed names.
func BootedSlot() string {
	e := BootedEntry()
	if !strings.HasPrefix(e, EntryPrefix) {
		return ""
	}
	switch rest := e[len(EntryPrefix):]; {
	case strings.HasPrefix(rest, SlotA):
		return SlotA
	case strings.HasPrefix(rest, SlotB):
		return SlotB
	}
	return ""
}

// Load reads the slot state, defaulting to {Active: "a"} when absent/unreadable
// (a fresh image booting slot A).
func Load() State { return LoadFrom(statePath) }

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
func (s State) Save() error { return s.SaveTo(statePath) }

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
