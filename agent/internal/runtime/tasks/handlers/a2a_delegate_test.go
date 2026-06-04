package handlers

import "testing"

func TestParseDelegation(t *testing.T) {
	// Full descriptor: peer_url + skill + args + token.
	d, err := parseDelegation(map[string]any{
		"peer_url":         "https://[fd00::2]:7777",
		"skill":            "embed-text",
		"args":             map[string]any{"model": "nomic", "input": "x"},
		"capability_token": map[string]any{"envelope": "ZW52", "signature": "c2ln"},
	})
	if err != nil {
		t.Fatal(err)
	}
	if d.PeerURL != "https://[fd00::2]:7777" || d.Skill != "embed-text" {
		t.Fatalf("parsed: %+v", d)
	}
	if d.Token.Envelope != "ZW52" || d.Token.Signature != "c2ln" {
		t.Fatalf("token: %+v", d.Token)
	}

	// peer_url derived from the first target_addresses entry.
	d2, err := parseDelegation(map[string]any{
		"target_addresses": []any{"[fd00::3]:7801", "[fd00::4]:7801"},
		"skill":            "ping",
		"capability_token": map[string]any{"envelope": "e", "signature": "s"},
	})
	if err != nil {
		t.Fatal(err)
	}
	if d2.PeerURL != "https://[fd00::3]:7801" {
		t.Fatalf("derived peer_url: %q", d2.PeerURL)
	}

	bad := []map[string]any{
		{"peer_url": "https://x", "skill": "ping"}, // no token
		{"peer_url": "https://x", "capability_token": map[string]any{"envelope": "e", "signature": "s"}},                       // no skill
		{"skill": "ping", "capability_token": map[string]any{"envelope": "e", "signature": "s"}},                              // no peer_url/addresses
		{"peer_url": "https://x", "skill": "ping", "capability_token": map[string]any{"envelope": "e"}},                       // half token
	}
	for i, opts := range bad {
		if _, err := parseDelegation(opts); err == nil {
			t.Fatalf("case %d: expected validation error for %v", i, opts)
		}
	}
}
