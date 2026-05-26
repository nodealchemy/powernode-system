package manifest

import "testing"

// TestServicesHashStable confirms hash determinism — identical service
// content yields identical hashes across two independent Manifest values.
// The reconciler diffs this hash against State.LastAttachedManifestHashes
// to decide whether already-attached modules need re-attach, so any
// non-determinism here would cause spurious re-attaches every cycle.
func TestServicesHashStable(t *testing.T) {
	a := &Manifest{
		Services: []Service{
			{Name: "qga", StartCommand: "/usr/sbin/qemu-ga", RestartPolicy: "always"},
		},
	}
	b := &Manifest{
		Services: []Service{
			{Name: "qga", StartCommand: "/usr/sbin/qemu-ga", RestartPolicy: "always"},
		},
	}
	if a.ServicesHash() != b.ServicesHash() {
		t.Errorf("expected identical hashes for identical services; got %s vs %s",
			a.ServicesHash(), b.ServicesHash())
	}
}

// TestServicesHashSensitiveToChanges confirms that any field change in
// the services block produces a different hash — start_command, name,
// dependency addition, env addition, etc. This is what makes the re-
// attach pass correct: if the hash matches, AttachServices skipped is
// safe; if it differs, re-attach is required.
func TestServicesHashSensitiveToChanges(t *testing.T) {
	baseline := &Manifest{
		Services: []Service{
			{Name: "qga", StartCommand: "/usr/sbin/qemu-ga", RestartPolicy: "always"},
		},
	}
	base := baseline.ServicesHash()

	cases := []struct {
		label string
		m     *Manifest
	}{
		{"start_command changed", &Manifest{Services: []Service{
			{Name: "qga", StartCommand: "/usr/bin/qemu-ga", RestartPolicy: "always"},
		}}},
		{"name changed", &Manifest{Services: []Service{
			{Name: "qemu-guest", StartCommand: "/usr/sbin/qemu-ga", RestartPolicy: "always"},
		}}},
		{"restart_policy changed", &Manifest{Services: []Service{
			{Name: "qga", StartCommand: "/usr/sbin/qemu-ga", RestartPolicy: "on-failure"},
		}}},
		{"env added", &Manifest{Services: []Service{
			{Name: "qga", StartCommand: "/usr/sbin/qemu-ga", RestartPolicy: "always",
				Env: map[string]string{"LOG_LEVEL": "debug"}},
		}}},
		{"additional service", &Manifest{Services: []Service{
			{Name: "qga", StartCommand: "/usr/sbin/qemu-ga", RestartPolicy: "always"},
			{Name: "qga-helper", StartCommand: "/usr/bin/qga-helper", RestartPolicy: "always"},
		}}},
	}
	for _, c := range cases {
		if c.m.ServicesHash() == base {
			t.Errorf("%s: expected hash to differ from baseline, got identical", c.label)
		}
	}
}

// TestServicesHashEmptyDeterministic — empty/nil services slices produce
// a stable non-empty hash (the SHA256 of "[]"). This matters for the
// re-attach pass: a freshly-mounted services-less module gets its hash
// recorded so subsequent cycles see "no change" and skip re-attach.
func TestServicesHashEmptyDeterministic(t *testing.T) {
	emptyA := &Manifest{Services: []Service{}}
	emptyB := &Manifest{Services: nil}
	if emptyA.ServicesHash() == "" {
		t.Errorf("empty services should still produce a non-empty hash, got empty")
	}
	if emptyA.ServicesHash() != emptyB.ServicesHash() {
		t.Errorf("nil-slice and empty-slice should hash to the same value; got %s vs %s",
			emptyA.ServicesHash(), emptyB.ServicesHash())
	}
}

// TestServicesHashNilReceiver — a nil Manifest must not panic; returns
// empty string. The reconciler can hit this when manifests fail to load.
func TestServicesHashNilReceiver(t *testing.T) {
	var m *Manifest
	if m.ServicesHash() != "" {
		t.Errorf("nil-receiver ServicesHash should return empty string")
	}
}
