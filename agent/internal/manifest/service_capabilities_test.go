package manifest

import (
	"encoding/json"
	"testing"
)

// IMP-caef5c00d63f — a service's own `capabilities:` key carries PRESENCE,
// not just a list. Absent means "inherit the module ceiling"; an explicit []
// means "zero". The three cases are pinned separately, and none of them may
// be decided by the list's length.

func decodeService(t *testing.T, body string) Service {
	t.Helper()
	var s Service
	if err := json.Unmarshal([]byte(body), &s); err != nil {
		t.Fatalf("unmarshal %s: %v", body, err)
	}
	return s
}

func TestServiceCapabilities_AbsentKeyIsNotDeclared(t *testing.T) {
	s := decodeService(t, `{"name":"rails-setup","start_command":"/bin/true"}`)
	if s.Capabilities.Declared {
		t.Fatalf("absent capabilities key must read as NOT declared (inherit), got %+v", s.Capabilities)
	}
}

func TestServiceCapabilities_ExplicitEmptyIsDeclaredZero(t *testing.T) {
	s := decodeService(t, `{"name":"rails","start_command":"/bin/true","capabilities":[]}`)
	if !s.Capabilities.Declared {
		t.Fatalf("explicit capabilities: [] must read as DECLARED (zero), got %+v", s.Capabilities)
	}
	if len(s.Capabilities.Names) != 0 {
		t.Fatalf("explicit [] must carry no names, got %v", s.Capabilities.Names)
	}
}

func TestServiceCapabilities_NonEmptyIsDeclared(t *testing.T) {
	s := decodeService(t, `{"name":"traefik","start_command":"/bin/true","capabilities":["CAP_NET_BIND_SERVICE"]}`)
	if !s.Capabilities.Declared {
		t.Fatalf("non-empty capabilities must read as DECLARED, got %+v", s.Capabilities)
	}
	if len(s.Capabilities.Names) != 1 || s.Capabilities.Names[0] != "CAP_NET_BIND_SERVICE" {
		t.Fatalf("names = %v, want [CAP_NET_BIND_SERVICE]", s.Capabilities.Names)
	}
}

// A NULL column (stage 1 stores NULL for "the manifest omitted the key") may
// reach the agent as an explicit JSON null; it means the same as absent.
func TestServiceCapabilities_NullIsNotDeclared(t *testing.T) {
	s := decodeService(t, `{"name":"rails-setup","start_command":"/bin/true","capabilities":null}`)
	if s.Capabilities.Declared {
		t.Fatalf("capabilities: null must read as NOT declared (inherit), got %+v", s.Capabilities)
	}
}

// The manifest cache (writeCache / LoadFromDisk) round-trips through
// json.Marshal. An `omitempty` []string dropped a declared [] on write, so it
// read back as absent — widening "zero" to "the whole ceiling" on the next
// cache-served reconcile. Presence must survive the round trip both ways.
func TestServiceCapabilities_PresenceSurvivesJSONRoundTrip(t *testing.T) {
	cases := map[string]bool{
		`{"name":"a","start_command":"/bin/true"}`:                              false,
		`{"name":"a","start_command":"/bin/true","capabilities":[]}`:            true,
		`{"name":"a","start_command":"/bin/true","capabilities":["CAP_CHOWN"]}`: true,
	}
	for in, wantDeclared := range cases {
		s := decodeService(t, in)
		out, err := json.Marshal(s)
		if err != nil {
			t.Fatalf("marshal: %v", err)
		}
		back := decodeService(t, string(out))
		if back.Capabilities.Declared != wantDeclared {
			t.Errorf("round trip of %s -> %s: Declared = %v, want %v", in, out, back.Capabilities.Declared, wantDeclared)
		}
		if len(back.Capabilities.Names) != len(s.Capabilities.Names) {
			t.Errorf("round trip of %s changed names: %v -> %v", in, s.Capabilities.Names, back.Capabilities.Names)
		}
	}
}
