package runtime

import (
	"encoding/json"
	"testing"
)

func mod(id, digest, manifest string) LKGModule {
	m := LKGModule{ID: id, Digest: digest}
	if manifest != "" {
		m.Manifest = json.RawMessage(manifest)
	}
	return m
}

// THE regression case. reverse-proxy-traefik shipped a build that added a
// restore-dynamic oneshot: same module id, and the agent renders units from the
// manifest — so treating this as "same composition" means the new service is
// never staged and never runs, while the delivery looks complete because the
// files are on disk.
func TestSameCompositionDetectsAddedService(t *testing.T) {
	before := []LKGModule{mod("m1", "sha256:aaa", `{"services":[{"name":"traefik"}]}`)}
	after := []LKGModule{mod("m1", "sha256:aaa", `{"services":[{"name":"restore-dynamic"},{"name":"traefik"}]}`)}

	if sameComposition(before, after) {
		t.Fatal("an added service must NOT compare as the same composition — the new unit would never be staged")
	}
}

// The protection the original digest-only comparison was written for: cosmetic
// churn must not restage, because every restage burns an attempt from the
// pending-compose budget.
func TestSameCompositionIgnoresCosmeticChurn(t *testing.T) {
	cases := []struct{ name, a, b string }{
		{
			"description and display name",
			`{"services":[{"name":"traefik"}],"description":"old","display_name":"A"}`,
			`{"services":[{"name":"traefik"}],"description":"new","display_name":"B"}`,
		},
		{
			"priority",
			`{"services":[{"name":"traefik"}],"priority":10}`,
			`{"services":[{"name":"traefik"}],"priority":99}`,
		},
		{
			"key order and whitespace",
			`{"services":[{"name":"traefik"}],"users":[{"name":"traefik"}]}`,
			"{ \"users\" : [ {\"name\":\"traefik\"} ] ,\n \"services\":[{\"name\":\"traefik\"}] }",
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			a := []LKGModule{mod("m1", "sha256:aaa", c.a)}
			b := []LKGModule{mod("m1", "sha256:aaa", c.b)}
			if !sameComposition(a, b) {
				t.Fatalf("cosmetic change restaged and burned an attempt: %s", c.name)
			}
		})
	}
}

// Every field that drives on-node rendering must count as behavioural.
func TestSameCompositionDetectsEachBehaviouralField(t *testing.T) {
	cases := []struct{ field, a, b string }{
		{"users", `{"users":[{"name":"a"}]}`, `{"users":[{"name":"b"}]}`},
		{"groups", `{"groups":[{"name":"a"}]}`, `{"groups":[{"name":"b"}]}`},
		{"security", `{"security":{"privileged":false}}`, `{"security":{"privileged":true}}`},
		{"sudoers", `{"sudoers":[{"user":"a"}]}`, `{"sudoers":[{"user":"b"}]}`},
		{"init", `{"init":{"start":"x"}}`, `{"init":{"start":"y"}}`},
	}
	for _, c := range cases {
		t.Run(c.field, func(t *testing.T) {
			a := []LKGModule{mod("m1", "sha256:aaa", c.a)}
			b := []LKGModule{mod("m1", "sha256:aaa", c.b)}
			if sameComposition(a, b) {
				t.Fatalf("a change to %q must restage — it changes what the node runs", c.field)
			}
		})
	}
}

// Digest comparison must keep working exactly as before.
func TestSameCompositionStillComparesDigestAndMembership(t *testing.T) {
	base := []LKGModule{mod("m1", "sha256:aaa", `{"services":[{"name":"s"}]}`)}

	if sameComposition(base, []LKGModule{mod("m1", "sha256:bbb", `{"services":[{"name":"s"}]}`)}) {
		t.Fatal("a changed digest must restage")
	}
	if sameComposition(base, []LKGModule{mod("m2", "sha256:aaa", `{"services":[{"name":"s"}]}`)}) {
		t.Fatal("a different module id must restage")
	}
	if sameComposition(base, []LKGModule{}) {
		t.Fatal("a different set size must restage")
	}
	// Order must not matter.
	two := []LKGModule{mod("m1", "sha256:aaa", `{}`), mod("m2", "sha256:bbb", `{}`)}
	rev := []LKGModule{mod("m2", "sha256:bbb", `{}`), mod("m1", "sha256:aaa", `{}`)}
	if !sameComposition(two, rev) {
		t.Fatal("comparison must stay order-insensitive")
	}
}

// A module with no manifest must compare equal to another with no manifest,
// or a fleet of manifest-less modules would restage on every single tick.
func TestSameCompositionHandlesAbsentAndUnparseableManifests(t *testing.T) {
	if !sameComposition(
		[]LKGModule{mod("m1", "sha256:aaa", "")},
		[]LKGModule{mod("m1", "sha256:aaa", "")},
	) {
		t.Fatal("two manifest-less modules must compare equal")
	}
	// Cosmetic-only manifest vs none: no behavioural fields either side, so equal.
	if !sameComposition(
		[]LKGModule{mod("m1", "sha256:aaa", "")},
		[]LKGModule{mod("m1", "sha256:aaa", `{"description":"x"}`)},
	) {
		t.Fatal("a manifest carrying only cosmetic fields must not restage")
	}
	// Corrupt manifests must compare consistently with themselves rather than
	// hashing to the same value as everything else.
	bad := `{"services":[`
	if !sameComposition(
		[]LKGModule{mod("m1", "sha256:aaa", bad)},
		[]LKGModule{mod("m1", "sha256:aaa", bad)},
	) {
		t.Fatal("identical unparseable manifests must compare equal")
	}
	if sameComposition(
		[]LKGModule{mod("m1", "sha256:aaa", bad)},
		[]LKGModule{mod("m1", "sha256:aaa", `{"services":[{"name":"s"}]}`)},
	) {
		t.Fatal("an unparseable manifest must not compare equal to a valid one")
	}
}
