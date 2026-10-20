package identity

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// N1: external media that is not USB is still removable.
func TestMediaScanTreatsSDThunderboltAndFirewireAsRemovable(t *testing.T) {
	m := newFakeMachine(t)
	m.addDisk("sdb", fakeDisk{})                                                                                             // internal
	m.addDisk("mmcblk0", fakeDisk{cardType: "SD"})                                                                           // native SD slot
	m.addDisk("mmcblk1", fakeDisk{cardType: "MMC"})                                                                          // eMMC: fixed
	m.addDisk("nvme0n1", fakeDisk{hostPath: "pci0000:00/0000:00:07.0/domain0/0-0/block", attrAt: "pci0000:00/0000:00:07.0"}) // thunderbolt port
	m.addDisk("sdf", fakeDisk{hostPath: "pci0000:00/0000:00:1c.0/firewire/fw0/block"})
	_, _ = m.strategy().Discover(context.Background())
	got := strings.Join(m.sniffs, ",")
	// fixed first (mmcblk1, sdb), then the removable ones in name order
	if got != "mmcblk1,sdb,mmcblk0,nvme0n1,sdf" {
		t.Fatalf("order = %s", got)
	}
}

func TestMediaScanSDCardDocumentCannotSupersedeTheSeedDisk(t *testing.T) {
	pki := newTestPKI(t)
	m := newFakeMachine(t)
	m.addDisk("sdb", fakeDisk{})
	m.addDisk("mmcblk0", fakeDisk{cardType: "SD"})
	m.media["sdb"] = vfatWith(docFor(pki, idA, "2026-10-20T09:00:00Z"))
	m.media["mmcblk0"] = vfatWith(docFor(pki, idA, "2026-10-20T11:00:00Z"))
	if _, err := m.strategy().Discover(context.Background()); !errors.Is(err, ErrProvisionRefused) {
		t.Fatalf("got %v", err)
	}
}

// N2: a fixed disk that enumerates late must still be seen when USB is already there.
func TestMediaScanWaitsFullEnumWaitEvenWhenUSBIsAlreadyPresent(t *testing.T) {
	pki := newTestPKI(t)
	m := newFakeMachine(t)
	m.addDisk("sdb", fakeDisk{usb: true, parts: []string{"sdb1"}})
	m.media["sdb1"] = vfatWith(docFor(pki, idB, "2026-10-20T11:00:00Z"))
	m.media["sdc"] = vfatWith(docFor(pki, idA, "2026-10-20T09:00:00Z"))
	s := m.strategy()
	s.EnumWait = 500 * time.Millisecond
	s.EnumPoll = 10 * time.Millisecond
	go func() {
		time.Sleep(100 * time.Millisecond)
		m.addDisk("sdc", fakeDisk{})
	}()
	if _, err := s.Discover(context.Background()); !errors.Is(err, ErrProvisionRefused) {
		t.Fatalf("the late fixed disk must be seen and disagree with the stick: %v", err)
	}
}

// N3: a fixed candidate that passed the sniff but did not finish cleanly blocks selection.
func TestMediaScanFixedCandidateThatFailedBLKROSETOrMountBlocksSelection(t *testing.T) {
	pki := newTestPKI(t)
	for name, setup := range map[string]func(m *fakeMachine){
		"blkroset": func(m *fakeMachine) { m.roErrDevs = map[string]error{"sdb": errors.New("EPERM")} },
		"mount":    func(m *fakeMachine) { m.mountFail = map[string]bool{"sdb": true} },
	} {
		for tier, seed := range map[string]string{"removable doc": "usb", "fixed doc": "fixed"} {
			m := newFakeMachine(t)
			m.addDisk("sdb", fakeDisk{}) // fixed, sorts first
			m.media["sdb"] = fakeMedia{fs: "vfat"}
			if seed == "usb" {
				m.addDisk("sdz", fakeDisk{usb: true})
				m.media["sdz"] = vfatWith(docFor(pki, idA, "2026-10-20T09:00:00Z"))
			} else {
				m.addDisk("sdc", fakeDisk{})
				m.media["sdc"] = vfatWith(docFor(pki, idA, "2026-10-20T09:00:00Z"))
			}
			setup(m)
			if _, err := m.strategy().Discover(context.Background()); !errors.Is(err, ErrNotFound) {
				t.Fatalf("%s/%s: want ErrNotFound, got %v", name, tier, err)
			}
		}
	}
}

// N4: a malformed document on REMOVABLE media must not block later sources.
func TestMediaScanRefusalFromRemovableMediaFallsThroughButFixedStaysTerminal(t *testing.T) {
	m := newFakeMachine(t)
	m.addDisk("sdb", fakeDisk{usb: true, parts: []string{"sdb1"}})
	m.media["sdb1"] = vfatWith("this is not a provisioning document, key " + testKey)
	s := m.strategy()
	next := &stubStrategy{id: &Identity{InstanceUUID: "fallback"}}
	id, err := (&Resolver{Strategies: []Strategy{s, next}}).Resolve(context.Background())
	if err != nil || id.InstanceUUID != "fallback" || !next.called {
		t.Fatalf("a bad stick must not block later strategies: id=%+v err=%v", id, err)
	}
	logged := strings.Join(m.logs, "\n")
	if !strings.Contains(logged, "sdb1") || strings.Contains(logged, testKey) {
		t.Fatalf("log must name the device and only that: %q", logged)
	}
	// SD card counts as removable too
	m = newFakeMachine(t)
	m.addDisk("mmcblk0", fakeDisk{cardType: "SD"})
	m.media["mmcblk0"] = vfatWith("garbage")
	if _, err := m.strategy().Discover(context.Background()); !errors.Is(err, ErrNotFound) {
		t.Fatalf("SD: %v", err)
	}
	// fixed media stays terminal (TestMediaScanStrictRefusalIsTerminal covers the Resolver side)
	m = newFakeMachine(t)
	m.addDisk("sdb", fakeDisk{})
	m.media["sdb"] = vfatWith("garbage")
	if _, err := m.strategy().Discover(context.Background()); !errors.Is(err, ErrProvisionRefused) {
		t.Fatalf("fixed: %v", err)
	}
}

func TestMediaScanOversizedFileOnRemovableMediaFallsThrough(t *testing.T) {
	pki := newTestPKI(t)
	m := newFakeMachine(t)
	m.addDisk("sdb", fakeDisk{usb: true, parts: []string{"sdb1"}})
	m.media["sdb1"] = vfatWith(docFor(pki, idA, "2026-10-20T10:00:00Z") + strings.Repeat(" ", provisionMaxDocBytes))
	if _, err := m.strategy().Discover(context.Background()); !errors.Is(err, ErrNotFound) {
		t.Fatalf("got %v", err)
	}
}

// N6: an unusable MountRoot restores the device state like every other early exit.
func TestMediaScanRestoresReadOnlyFlagWhenMountRootIsUnusable(t *testing.T) {
	m := newFakeMachine(t)
	m.addDisk("sdb", fakeDisk{removable: true, parts: []string{"sdb1"}})
	m.media["sdb1"] = fakeMedia{fs: "vfat"}
	blocker := filepath.Join(t.TempDir(), "file")
	os.WriteFile(blocker, nil, 0o600)
	s := m.strategy()
	s.MountRoot = filepath.Join(blocker, "media") // MkdirAll fails: parent is a file
	_, _ = s.Discover(context.Background())
	if got := strings.Join(m.events, ","); got != "ro:sdb1,restore:sdb1" {
		t.Fatalf("events = %s", got)
	}
}

// N7: starvation of FIXED candidates.
func TestMediaScanStarvedFixedCandidateBlocksAnotherFixedDocument(t *testing.T) {
	pki := newTestPKI(t)
	m := newFakeMachine(t)
	m.addDisk("sdb", fakeDisk{})
	m.addDisk("sdc", fakeDisk{})
	m.media["sdb"] = vfatWith(docFor(pki, idA, "2026-10-20T09:00:00Z"))
	m.media["sdc"] = fakeMedia{fs: "vfat"}
	m.gateDevs = map[string]chan struct{}{"sdc": make(chan struct{})} // wedged fixed disk
	defer close(m.gateDevs["sdc"])
	s := m.strategy()
	s.Budget = 300 * time.Millisecond
	if _, err := s.Discover(context.Background()); !errors.Is(err, ErrNotFound) {
		t.Fatalf("a fixed document must not be used while another fixed disk is starved: %v", err)
	}
}

func TestMediaScanUnprobedFixedCandidateBlocksTheFixedDocumentAlreadyRead(t *testing.T) {
	pki := newTestPKI(t)
	m := newFakeMachine(t)
	m.addDisk("sdb", fakeDisk{})
	m.addDisk("sdc", fakeDisk{})
	m.media["sdb"] = vfatWith(docFor(pki, idA, "2026-10-20T09:00:00Z"))
	m.media["sdc"] = vfatWith(docFor(pki, idA, "2026-10-20T09:00:00Z"))
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	s := m.strategy()
	inner := s.Logf
	s.Logf = func(f string, a ...any) { // the budget runs out between the two probes
		inner(f, a...)
		if strings.Contains(f, "probing") && len(a) == 1 && a[0] == "sdc" {
			cancel()
		}
	}
	if _, err := s.Discover(ctx); !errors.Is(err, ErrNotFound) {
		t.Fatalf("an unprobed fixed disk must block selection: %v", err)
	}
	if len(m.calls) != 1 {
		t.Fatalf("sdc must not have been probed: %v", m.calls)
	}
}

func TestMediaScanWedgedSeedDiskStopsAUSBDocumentFromWinning(t *testing.T) {
	pki := newTestPKI(t)
	m := newFakeMachine(t)
	m.addDisk("sdd", fakeDisk{parts: []string{"sdd1"}})
	m.label("cidata", "sdd1")
	m.addDisk("sdb", fakeDisk{usb: true, parts: []string{"sdb1"}})
	m.media["sdd1"] = fakeMedia{fs: "iso9660"}
	m.media["sdb1"] = vfatWith(docFor(pki, idA, "2026-10-20T09:00:00Z"))
	m.gateDevs = map[string]chan struct{}{"sdd1": make(chan struct{})}
	defer close(m.gateDevs["sdd1"])
	s := m.strategy()
	s.Budget = 300 * time.Millisecond
	if _, err := s.Discover(context.Background()); !errors.Is(err, ErrNotFound) {
		t.Fatalf("got %v", err)
	}
}
