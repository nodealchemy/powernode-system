package oci

import (
	"encoding/base64"
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

// TestPullMaterialisesInlineCosignBundle pins the module signature TRANSPORT.
//
// History: until this transport landed, Pull's second return value was a
// CONSTRUCTED filename that nothing ever wrote, and a test of the opposite
// name (TestPullFetchesNoCosignBundle) pinned that fact so the verifier-wiring
// decision could not be made by accident. The transport now exists: the
// platform serves a `cosign sign-blob` bundle over the erofs bytes INLINE
// (base64, on the module manifest and the download envelope — the same shape
// the boot path uses for its UKI bundle), the ref carries it, and Pull writes
// it beside the blob. There is deliberately NO second network fetch: the
// bundle rides the manifest the reconciler already has, so an LKG boot with a
// frozen manifest carries its signatures too.
//
// This test asserts the bytes, both ways: a ref WITH a bundle materialises
// exactly those bytes; a ref WITHOUT one materialises nothing (so a module the
// platform never signed presents a missing bundle to the verifier, which
// refuses it by name — see verify.CosignVerifier). Either way the blob is the
// only request.
func TestPullMaterialisesInlineCosignBundle(t *testing.T) {
	payload := []byte("erofs blob bytes")
	digest := sha256Hex(payload)
	bundle := []byte(`{"mediaType":"application/vnd.dev.sigstore.bundle+json;version=0.3","pretend":"bundle"}`)

	var requested []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requested = append(requested, r.URL.Path)
		w.Write(payload)
	}))
	defer srv.Close()

	t.Run("with a bundle", func(t *testing.T) {
		requested = nil
		p := &Puller{HTTPClient: srv.Client(), PlatformURL: srv.URL, Cache: t.TempDir()}
		ref := &ModuleArtifactRef{
			ModuleID:        "mod-signed",
			Digest:          digest,
			DownloadURL:     "/api/v1/system/node_api/files/modules/mod-signed",
			Size:            int64(len(payload)),
			CosignBundleB64: base64.StdEncoding.EncodeToString(bundle),
		}
		cfsPath, bundlePath, err := p.Pull(ref)
		if err != nil {
			t.Fatalf("Pull: %v", err)
		}
		if _, err := os.Stat(cfsPath); err != nil {
			t.Fatalf("erofs blob should exist after a successful pull: %v", err)
		}
		got, err := os.ReadFile(bundlePath)
		if err != nil {
			t.Fatalf("bundle should be materialised at %s: %v", bundlePath, err)
		}
		if string(got) != string(bundle) {
			t.Fatalf("bundle bytes: got %q, want %q", got, bundle)
		}
		if st, _ := os.Stat(bundlePath); st.Mode().Perm() != 0o600 {
			t.Fatalf("bundle perms: got %o, want 0600", st.Mode().Perm())
		}
		// Inline means inline: still exactly one request, for the blob.
		if len(requested) != 1 || requested[0] != ref.DownloadURL {
			t.Fatalf("requests: got %v, want exactly one blob fetch of %q", requested, ref.DownloadURL)
		}

		// Idempotent re-pull (blob already cached) must still (re)write the
		// bundle: a backfill can sign an artifact AFTER a node cached its blob.
		if err := os.Remove(bundlePath); err != nil {
			t.Fatal(err)
		}
		requested = nil
		if _, bp2, err := p.Pull(ref); err != nil {
			t.Fatalf("second Pull: %v", err)
		} else if _, err := os.Stat(bp2); err != nil {
			t.Fatalf("cached-blob path must still materialise the bundle: %v", err)
		}
		if len(requested) != 0 {
			t.Fatalf("cached blob must not be re-fetched: %v", requested)
		}
	})

	t.Run("without a bundle", func(t *testing.T) {
		requested = nil
		p := &Puller{HTTPClient: srv.Client(), PlatformURL: srv.URL, Cache: t.TempDir()}
		ref := &ModuleArtifactRef{
			ModuleID:    "mod-unsigned",
			Digest:      digest,
			DownloadURL: "/api/v1/system/node_api/files/modules/mod-unsigned",
			Size:        int64(len(payload)),
		}
		cfsPath, bundlePath, err := p.Pull(ref)
		if err != nil {
			t.Fatalf("Pull: %v", err)
		}
		if _, err := os.Stat(cfsPath); err != nil {
			t.Fatalf("erofs blob should exist after a successful pull: %v", err)
		}
		if _, err := os.Stat(bundlePath); !os.IsNotExist(err) {
			t.Fatalf("no bundle was served, so none may be materialised (got err=%v)", err)
		}
		if len(requested) != 1 {
			t.Fatalf("requests: got %v, want exactly one blob fetch", requested)
		}
	})

	t.Run("with a malformed bundle", func(t *testing.T) {
		requested = nil
		p := &Puller{HTTPClient: srv.Client(), PlatformURL: srv.URL, Cache: t.TempDir()}
		ref := &ModuleArtifactRef{
			ModuleID:        "mod-garbage",
			Digest:          digest,
			DownloadURL:     "/api/v1/system/node_api/files/modules/mod-garbage",
			CosignBundleB64: "not base64!!",
		}
		if _, _, err := p.Pull(ref); err == nil {
			t.Fatal("a bundle that cannot be decoded must fail the pull, not be silently dropped")
		}
		// Fail BEFORE the network: no partial state to reason about.
		if len(requested) != 0 {
			t.Fatalf("malformed bundle must be rejected before fetching the blob: %v", requested)
		}
	})
}

// TestFetchManifestCarriesSignatureMaterial pins the decoder half: the
// download envelope's `oci` block now carries cosign_bundle_b64 and the
// platform's trusted public keys, and ModuleArtifactRef has fields for both.
//
// The predecessor test (TestFetchManifestCarriesNoSignatureMaterial) asserted
// the ABSENCE of these fields reflectively so that adding one would fail
// loudly and force the verifier-wiring decision. That decision is now made
// (verify.NewModuleVerifier, default off); this asserts presence instead.
func TestFetchManifestCarriesSignatureMaterial(t *testing.T) {
	body := `{
		"success": true,
		"data": {
			"file": {"name": "module.erofs", "size": 16, "checksum": "cafe",
			         "download_url": "/files/modules/m1"},
			"oci": {"ref": "registry.example/mod@sha256:cafe", "digest": "sha256:cafe",
			        "cosign_bundle_b64": "aWdub3JlZA==",
			        "cosign_public_keys": ["-----BEGIN PUBLIC KEY-----\nAAA\n-----END PUBLIC KEY-----\n",
			                               "-----BEGIN PUBLIC KEY-----\nBBB\n-----END PUBLIC KEY-----\n"]}
		}
	}`
	c := &stubClient{resp: makeJSONResp(200, body)}
	p := &Puller{Transport: c, Cache: t.TempDir()}

	ref, err := p.FetchManifest("m1")
	if err != nil {
		t.Fatalf("FetchManifest: %v", err)
	}
	if ref.Digest != "cafe" || ref.DownloadURL != "/files/modules/m1" {
		t.Fatalf("ref did not decode the fields it already supported: %+v", ref)
	}
	for _, field := range []string{"CosignBundleB64", "CosignPublicKeys"} {
		if !hasField(ref, field) {
			t.Fatalf("ModuleArtifactRef lost field %q — the signature transport seam", field)
		}
	}
	if ref.CosignBundleB64 != "aWdub3JlZA==" {
		t.Fatalf("cosign_bundle_b64 not carried: %q", ref.CosignBundleB64)
	}
	if len(ref.CosignPublicKeys) != 2 || ref.CosignPublicKeys[1] != "-----BEGIN PUBLIC KEY-----\nBBB\n-----END PUBLIC KEY-----\n" {
		t.Fatalf("cosign_public_keys not carried: %q", ref.CosignPublicKeys)
	}
}
