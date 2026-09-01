package oci

import (
	"net/http"
	"net/http/httptest"
	"os"
	"reflect"
	"testing"
)

// hasField reports whether v's struct type declares a field named name.
func hasField(v any, name string) bool {
	t := reflect.TypeOf(v)
	for t != nil && t.Kind() == reflect.Ptr {
		t = t.Elem()
	}
	if t == nil || t.Kind() != reflect.Struct {
		return false
	}
	_, ok := t.FieldByName(name)
	return ok
}

// TestPullFetchesNoCosignBundle pins the fact that decides whether module
// signature enforcement is even POSSIBLE today: Pull returns a bundlePath but
// never fetches, writes, or otherwise materialises a bundle.
//
// Pull's second return value is a CONSTRUCTED filename (pull.go: filepath.Join
// of the cache dir and "<digest>.cosign-bundle"), not a downloaded file. The
// only network fetch Pull performs is streamToFile for the erofs blob. Nothing
// anywhere in the agent writes a module cosign bundle — the platform's
// /modules/:id/download envelope carries no signature field for one to come
// from, and ModuleArtifactRef has nowhere to put it.
//
// The consequence is the point. Swapping verify.AlwaysOK for a real
// verify.CosignVerifier at the three reconciler construction sites would not
// tighten a control, it would refuse EVERY module mount on EVERY node, because
// `cosign verify-blob --bundle <path>` cannot succeed against a path that does
// not exist. Module signature enforcement is therefore blocked on a missing
// TRANSPORT, not on a configuration flag and not on the population of signed
// artifacts — and transport is only half of it: the platform signs modules with
// `cosign sign` over an OCI ref, not `cosign sign-blob` over these bytes, so
// there is no bundle to transport in the first place. See internal/verify/doc.go.
//
// The sibling TestPullStreamsAndVerifies asserts only that bundlePath has the
// right SUFFIX, which holds whether or not the file was ever fetched — it reads
// like bundle coverage and is not. This test asserts the bytes.
//
// When a bundle transport lands, this test SHOULD fail. That is its job: it
// forces the verifier-wiring decision to be made deliberately rather than left
// at the Phase 1 development default. See internal/verify/doc.go for the
// ordered prerequisites.
func TestPullFetchesNoCosignBundle(t *testing.T) {
	payload := []byte("erofs blob bytes")
	digest := sha256Hex(payload)

	var requested []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requested = append(requested, r.URL.Path)
		w.Write(payload)
	}))
	defer srv.Close()

	cache := t.TempDir()
	p := &Puller{HTTPClient: srv.Client(), PlatformURL: srv.URL, Cache: cache}
	ref := &ModuleArtifactRef{
		ModuleID:    "mod-bundle-gap",
		Digest:      digest,
		DownloadURL: "/api/v1/system/node_api/files/modules/mod-bundle-gap",
		Size:        int64(len(payload)),
	}

	cfsPath, bundlePath, err := p.Pull(ref)
	if err != nil {
		t.Fatalf("Pull: %v", err)
	}

	// The blob IS fetched and IS present.
	if _, err := os.Stat(cfsPath); err != nil {
		t.Fatalf("erofs blob should exist after a successful pull: %v", err)
	}

	// The bundle is NOT. If this assertion starts failing, a bundle transport
	// has been added: update internal/verify/doc.go and decide the verifier
	// wiring at the three reconciler construction sites in the same change.
	if _, err := os.Stat(bundlePath); !os.IsNotExist(err) {
		t.Fatalf("bundle at %s: expected os.IsNotExist, got err=%v — a bundle "+
			"transport now exists; re-decide the module-mount Verifier wiring "+
			"and refresh internal/verify/doc.go", bundlePath, err)
	}

	// Exactly one request, for the blob. No second fetch for a signature.
	if len(requested) != 1 {
		t.Fatalf("requests: got %v, want exactly one blob fetch", requested)
	}
	if requested[0] != ref.DownloadURL {
		t.Fatalf("requested %q, want the blob path %q", requested[0], ref.DownloadURL)
	}
}

// TestFetchManifestCarriesNoSignatureMaterial pins the other half of the gap:
// even if the agent wanted to fetch a bundle, the platform's download envelope
// gives it no reference to fetch.
//
// The node_api download action renders ref / digest / fsverity_root_hash /
// size_bytes. There is no signature, bundle, bundle_url, or public-key field,
// and ModuleArtifactRef has no field that could receive one. (That action's
// comment used to claim its `oci` block supplied "cosign material"; it never
// did, and the comment now says so.)
//
// Note the contrast with fs-verity, which has a wire channel that at least
// EXISTS end to end (fsverity_root_hash, published by the build handler and
// carried on the manifest) — though it is populated only on the native publish
// path. Cosign has no such channel at all, and, more fundamentally, the
// platform signs an OCI ref rather than the erofs blob this package's Verifier
// knows how to check. See internal/verify/doc.go.
//
// This asserts the decoder's behaviour, not the server's: signature fields
// present in the response are silently dropped, so a platform that started
// serving one would ship it into a void until the ref struct is extended.
func TestFetchManifestCarriesNoSignatureMaterial(t *testing.T) {
	// A response that DOES carry signature material, to prove the decoder
	// discards it rather than that the fixture merely omitted it.
	body := `{
		"success": true,
		"data": {
			"file": {"name": "module.erofs", "size": 16, "checksum": "cafe",
			         "download_url": "/files/modules/m1",
			         "cosign_bundle_url": "/files/modules/m1/bundle"},
			"oci": {"ref": "registry.example/mod@sha256:cafe", "digest": "sha256:cafe",
			        "cosign_bundle_b64": "aWdub3JlZA==",
			        "cosign_public_key": "-----BEGIN PUBLIC KEY-----"}
		}
	}`
	c := &stubClient{resp: makeJSONResp(200, body)}
	p := &Puller{Transport: c, Cache: t.TempDir()}

	ref, err := p.FetchManifest("m1")
	if err != nil {
		t.Fatalf("FetchManifest: %v", err)
	}

	// Everything the ref CAN carry, it carried — so a nil ref is not why the
	// signature fields are absent below.
	if ref.Digest != "cafe" || ref.DownloadURL != "/files/modules/m1" {
		t.Fatalf("ref did not decode the fields it does support: %+v", ref)
	}

	// ModuleArtifactRef has no signature-bearing field at all. Reflectively
	// asserting the absence keeps this honest if someone adds one: the struct
	// growing a cosign field is exactly the seam this test is watching for.
	for _, forbidden := range []string{"CosignBundle", "BundleURL", "Signature", "CosignPublicKey"} {
		if hasField(ref, forbidden) {
			t.Fatalf("ModuleArtifactRef gained field %q — the signature transport "+
				"seam is being built; wire Puller.Pull to fetch it and re-decide "+
				"the module-mount Verifier wiring", forbidden)
		}
	}
}
