package identity

import (
	"context"
	"errors"
	"os"
	"strings"
	"testing"
	"time"
)

// F1: a USB stick labelled CIDATA must not count as fixed media.
func TestReviewCidataLabelOnUSBWins(t *testing.T) {
	pki := newTestPKI(t)
	m := newFakeMachine(t)
	m.addDisk("sdb", fakeDisk{usb: true, parts: []string{"sdb1"}}) // removable=0 AND labelled cidata
	m.addDisk("sdc", fakeDisk{})                                   // genuine internal disk
	m.label("cidata", "sdb1")
	m.media["sdb1"] = vfatWith(docWith(pki, idB, "2026-10-20T11:00:00Z", "https://evil.example.test", otherPin))
	m.media["sdc"] = vfatWith(docFor(pki, idA, "2026-10-20T09:00:00Z"))
	_, err := m.strategy().Discover(context.Background())
	if !errors.Is(err, ErrProvisionRefused) {
		t.Fatalf("a USB doc disagreeing with fixed media must be refused, got %v", err)
	}
	if got := strings.Join(m.sniffs, ","); got != "sdc,sdb1" {
		t.Fatalf("USB (even cidata-labelled) must be probed last: %s", got)
	}
}

func TestMediaScanClassifiesByBusNotByFlagOrType(t *testing.T) {
	m := newFakeMachine(t)
	m.addDisk("sda", fakeDisk{usb: true}) // USB disk claiming removable=0
	m.addDisk("sdb", fakeDisk{})          // internal
	m.addDisk("sr0", fakeDisk{usb: true, removable: true})
	m.addDisk("sr1", fakeDisk{removable: true}) // internal SATA/virtio CD-ROM: removable=1 but not USB
	_, _ = m.strategy().Discover(context.Background())
	if got := strings.Join(m.sniffs, ","); got != "sr1,sdb,sda,sr0" {
		t.Fatalf("order = %s, want fixed (sr1, sdb) then USB (sda, sr0)", got)
	}
}

// F2: budget starvation must not let removable media win by default.
func TestMediaScanRemovableDocumentIsDroppedAfterAnAbandonedRemovableProbe(t *testing.T) {
	pki := newTestPKI(t)
	m := newFakeMachine(t)
	m.addDisk("sdb", fakeDisk{usb: true, parts: []string{"sdb1"}})
	m.addDisk("sdc", fakeDisk{usb: true, parts: []string{"sdc1"}})
	m.media["sdb1"] = vfatWith(docFor(pki, idA, "2026-10-20T10:00:00Z"))
	m.media["sdc1"] = fakeMedia{fs: "vfat"}
	m.gateDevs = map[string]chan struct{}{"sdc1": make(chan struct{})} // wedged stick
	defer close(m.gateDevs["sdc1"])
	s := m.strategy()
	s.Budget = 300 * time.Millisecond
	_, err := s.Discover(context.Background())
	if !errors.Is(err, ErrNotFound) {
		t.Fatalf("a removable document chosen after an abandoned probe must not be used: %v", err)
	}
	if _, serr := os.Stat(m.path("run/powernode/identity.cfg")); !os.IsNotExist(serr) {
		t.Fatal("nothing may be staged")
	}
}

func TestMediaScanFixedMediaStillWinsWhenOnlyUSBWasStarved(t *testing.T) {
	pki := newTestPKI(t)
	m := newFakeMachine(t)
	m.addDisk("sdb", fakeDisk{usb: true, parts: []string{"sdb1"}})
	m.addDisk("sdc", fakeDisk{})
	m.media["sdb1"] = fakeMedia{fs: "vfat"}
	m.media["sdc"] = vfatWith(docFor(pki, idA, "2026-10-20T10:00:00Z"))
	m.gateDevs = map[string]chan struct{}{"sdb1": make(chan struct{})}
	defer close(m.gateDevs["sdb1"])
	s := m.strategy()
	s.Budget = 300 * time.Millisecond
	id, err := s.Discover(context.Background())
	if err != nil || id.InstanceUUID != idA {
		t.Fatalf("id=%+v err=%v", id, err)
	}
}

// F3: removable and fixed documents must be identical, or the scan refuses.
func TestReviewSameServerNewerUSBWins(t *testing.T) {
	pki := newTestPKI(t)
	m := newFakeMachine(t)
	m.addDisk("sdb", fakeDisk{usb: true, parts: []string{"sdb1"}})
	m.addDisk("sdc", fakeDisk{})
	m.media["sdb1"] = vfatWith(docFor(pki, idB, "2026-10-20T11:00:00Z")) // same server+pin, newer
	m.media["sdc"] = vfatWith(docFor(pki, idA, "2026-10-20T09:00:00Z"))
	for range 2 {
		m.calls, m.events, m.sniffs = nil, nil, nil
		if _, err := m.strategy().Discover(context.Background()); !errors.Is(err, ErrProvisionRefused) {
			t.Fatalf("want refusal, got %v", err)
		}
	}
}

func TestMediaScanIdenticalUSBAndFixedDocumentsAreFine(t *testing.T) {
	pki := newTestPKI(t)
	doc := docFor(pki, idA, "2026-10-20T10:00:00Z")
	m := newFakeMachine(t)
	m.addDisk("sdb", fakeDisk{usb: true, parts: []string{"sdb1"}})
	m.addDisk("sdc", fakeDisk{})
	m.media["sdb1"] = vfatWith(doc)
	m.media["sdc"] = vfatWith(doc)
	if id, err := m.strategy().Discover(context.Background()); err != nil || id.InstanceUUID != idA {
		t.Fatalf("id=%+v err=%v", id, err)
	}
}

// F4: BLKROSET is restored after a CLEAN unmount only.
func TestMediaScanRestoresPreviousBlockStateAfterCleanUnmount(t *testing.T) {
	m := newFakeMachine(t)
	m.addDisk("sdb", fakeDisk{removable: true, parts: []string{"sdb1"}})
	m.media["sdb1"] = fakeMedia{fs: "vfat"}
	if _, err := m.strategy().Discover(context.Background()); !errors.Is(err, ErrNotFound) {
		t.Fatal(err)
	}
	want := "ro:sdb1,mount:sdb1,unmount:detach=false,restore:sdb1"
	if got := strings.Join(m.events, ","); got != want {
		t.Fatalf("events = %s, want %s", got, want)
	}
}

func TestMediaScanLeavesDeviceReadOnlyWhenUnmountWasDetachedOrAbandoned(t *testing.T) {
	// detached after a failed clean unmount
	m := newFakeMachine(t)
	m.addDisk("sdb", fakeDisk{removable: true, parts: []string{"sdb1"}})
	m.media["sdb1"] = fakeMedia{fs: "vfat"}
	m.unmountErrFirst = true
	_, _ = m.strategy().Discover(context.Background())
	for _, e := range m.events {
		if strings.HasPrefix(e, "restore:") {
			t.Fatalf("restored after a detached unmount: %v", m.events)
		}
	}
	// abandoned: late mount past the budget
	m = newFakeMachine(t)
	m.addDisk("sdb", fakeDisk{removable: true, parts: []string{"sdb1"}})
	m.media["sdb1"] = fakeMedia{fs: "vfat"}
	m.gate = make(chan struct{})
	s := m.strategy()
	s.Budget = 100 * time.Millisecond
	_, _ = s.Discover(context.Background())
	close(m.gate)
	eventually(t, "late detach", func() bool { m.mu.Lock(); defer m.mu.Unlock(); return len(m.detaches) == 1 })
	time.Sleep(50 * time.Millisecond)
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, e := range m.events {
		if strings.HasPrefix(e, "restore:") {
			t.Fatalf("restored after an abandoned mount: %v", m.events)
		}
	}
}

// F5: never fail open when mountinfo is unreadable.
func TestMediaScanAbortsWhenMountInfoIsUnreadable(t *testing.T) {
	m := newFakeMachine(t)
	m.addDisk("sda", fakeDisk{parts: []string{"sda1"}}) // would be the root disk
	m.media["sda1"] = fakeMedia{fs: "ext4"}
	os.Remove(m.path("proc-mountinfo"))
	_, err := m.strategy().Discover(context.Background())
	if !errors.Is(err, ErrNotFound) {
		t.Fatalf("got %v", err)
	}
	if len(m.sniffs) != 0 || len(m.events) != 0 {
		t.Fatalf("devices were touched without a mount table: %v %v", m.sniffs, m.events)
	}
	if len(m.logs) == 0 {
		t.Fatal("the abort must be logged")
	}
}
