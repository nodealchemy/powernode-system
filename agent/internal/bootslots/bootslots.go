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

// EntryName returns the /EFI/Linux basename for a slot. With tries > 0 it
// carries the systemd-boot boot-counter suffix (powernode-a+3.efi); with
// tries <= 0 it is the permanent-good name (powernode-a.efi).
func EntryName(slot string, tries int) string {
	if tries > 0 {
		return fmt.Sprintf("%s%s+%d.efi", EntryPrefix, slot, tries)
	}
	return fmt.Sprintf("%s%s.efi", EntryPrefix, slot)
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
