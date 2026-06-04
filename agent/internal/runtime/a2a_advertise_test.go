package runtime

import "testing"

func TestA2AAdvertiseAddrs(t *testing.T) {
	// IPv6 overlay + port -> bracketed host:port.
	if got := a2aAdvertiseAddrs("fd00::2", ":7777"); len(got) != 1 || got[0] != "[fd00::2]:7777" {
		t.Fatalf("ipv6: got %v", got)
	}
	// IPv4 overlay.
	if got := a2aAdvertiseAddrs("10.0.0.5", ":7801"); len(got) != 1 || got[0] != "10.0.0.5:7801" {
		t.Fatalf("ipv4: got %v", got)
	}
	// Empty overlay -> nil (skills still announced; address fills in later).
	if a2aAdvertiseAddrs("", ":7777") != nil {
		t.Fatal("expected nil when overlay is empty")
	}
	// Unparseable listen addr -> nil.
	if a2aAdvertiseAddrs("fd00::2", "garbage") != nil {
		t.Fatal("expected nil on unparseable listen addr")
	}
}
