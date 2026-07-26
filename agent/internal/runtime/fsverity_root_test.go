package runtime

import (
	"encoding/json"
	"testing"
)

// The fs-verity Merkle root and the OCI blob digest are DIFFERENT hashes of the
// same file, and the mount path used to pass the blob digest where the root was
// expected. That comparison can never match, so every module mount would have
// failed the moment fs-verity was switched on — dormant only because the
// verifier is nil by default. These pin the two apart.
func TestLKGFsverityRootIsNotTheBlobDigest(t *testing.T) {
	const (
		blobDigest = "sha256:3122edb04a203fa622b277d94ebb707bf66cc36dea818a221b76fddf3bd8efdd"
		fsvRoot    = "sha256:87a45783dcf180443468c50ad935c63e6403137ede6ab135e6746e95268fcb91"
	)
	m := LKGModule{
		ID:       "mod-1",
		Digest:   blobDigest,
		Manifest: json.RawMessage(`{"digest":"` + blobDigest + `","fsverity_root_hash":"` + fsvRoot + `"}`),
	}

	got := lkgFsverityRoot(m)
	if got != fsvRoot {
		t.Fatalf("fsverity root = %q, want %q", got, fsvRoot)
	}
	if got == m.Digest {
		t.Fatal("returned the blob digest instead of the Merkle root — this is the original bug")
	}
}

// Absent or unreadable manifests must yield "", which the mount path treats as
// "refuse to mount while fs-verity is enabled" rather than as a bypass.
func TestLKGFsverityRootEmptyWhenUnavailable(t *testing.T) {
	cases := []struct {
		name string
		mod  LKGModule
	}{
		{"no manifest", LKGModule{ID: "m", Digest: "sha256:aa"}},
		{"manifest without the field", LKGModule{ID: "m", Manifest: json.RawMessage(`{"digest":"sha256:aa"}`)}},
		{"unparseable manifest", LKGModule{ID: "m", Manifest: json.RawMessage(`{"fsverity_root_hash":`)}},
		{"explicitly empty", LKGModule{ID: "m", Manifest: json.RawMessage(`{"fsverity_root_hash":""}`)}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := lkgFsverityRoot(c.mod); got != "" {
				t.Fatalf("expected empty root, got %q — an unverifiable module must not look verifiable", got)
			}
		})
	}
}
