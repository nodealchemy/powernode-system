// Package oci pulls module artifacts to a local cache.
//
// Phase 1 rewrite: the agent fetches manifest metadata from the
// platform's /api/v1/system/node_api/modules/:id/download endpoint
// and streams the artifact bytes via the same mTLS transport. No
// `oras` shell dependency — keeps the static binary lean and
// auth-uniform with the rest of the agent.
//
// THE AGENT NEVER TALKS TO THE OCI REGISTRY. Every byte comes from the
// platform's download_url; there is no registry client in this binary (no
// /v2/ manifest or blob calls anywhere in the agent). Pull errors out rather
// than falling back if that URL cannot be resolved.
//
// This comment previously described the opposite — "oci_ref + digest pulled
// directly from the OCI registry, with download_url as a platform-proxied
// fallback for air-gapped fleets". No such branch has ever existed here, and
// the stale wording actively misled a 2026-07-29 investigation into
// concluding that every node needed registry egress. Corrected to match the
// code; if a registry path is ever added, change the code and this comment
// together.
//
// Why platform-only is the design, not a limitation:
//   - ONE egress path. Nodes need to reach the platform and nothing else;
//     no per-node registry credentials or allowlist entries.
//   - ONE fleet-wide cache. The platform side
//     (Api::V1::System::NodeApi::FilesController -> OciBlobProxyService) is a
//     digest-addressed read-through cache, so the first node to want a digest
//     pays the registry fetch and every other node is served from disk.
//   - A registry outage degrades instead of blocking, as long as the platform
//     already holds the blob.
//
// Integrity does not depend on the transport: Digest is REQUIRED, the stream
// is sha256'd inline, and a mismatch deletes the temp file and fails the pull.
// So proxying through the platform grants it no ability to substitute bytes.
//
// Reference: Golden Eclipse plan M2.D.5; M1 supply chain.
package oci

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
)

// Client is the minimal subset of *transport.Client the puller needs
// for the manifest fetch. Defined as an interface so tests can stub.
type Client interface {
	GetJSON(path string) (*http.Response, error)
}

// ModuleArtifactRef describes one published module artifact.
// Mirrors the JSON shape returned by /api/v1/system/node_api/modules/:id/download.
type ModuleArtifactRef struct {
	ModuleID string
	// OCIRef is INFORMATIONAL ONLY — carried through from the platform
	// response for provenance/logging. Pull never fetches from it and there is
	// no registry client in this binary. (It previously read "when set, prefer
	// the OCI registry path", which was never true and misled a reader into
	// believing nodes required registry egress.)
	OCIRef string
	// Digest is what actually guarantees integrity: REQUIRED, verified inline
	// against the streamed bytes, mismatch deletes the temp file and fails.
	Digest string // sha256 hex, with or without the "sha256:" prefix
	// DownloadURL is the ONLY fetch path — the platform's digest-addressed
	// proxy. Relative; resolved against Puller.PlatformURL.
	DownloadURL string
	Size        int64
	Checksum    string // sha256 hex (redundant with Digest)
	// CosignBundleB64 is the platform's `cosign sign-blob` bundle over the
	// erofs bytes, base64 — the SIGNING SUBJECT the Verifier interface can
	// actually check, distinct from the OCI image signature the platform also
	// pushes to the registry as a .sig tag. Carried INLINE (the boot path's
	// cosign_bundle_b64 shape), so there is no second fetch and an LKG boot
	// with a frozen manifest carries its signatures too. Pull writes it to
	// the returned bundlePath. Empty when the platform published no blob
	// signature for this artifact; a static-key verifier then refuses the
	// mount by name.
	CosignBundleB64 string
	// CosignPublicKeys are the platform's trusted module-signing PUBLIC keys
	// (PEM), the same list served at /node_api/modules/signing_keys and used
	// server-side at ingest. Informational on this ref: the runtime obtains
	// its trust anchor at construction (runtime.ResolveModuleVerifier), not
	// per artifact. Public, not secret.
	CosignPublicKeys []string
}

// Puller downloads OCI artifacts to a local cache.
type Puller struct {
	// Transport is used for the manifest GET (small JSON response).
	Transport Client
	// HTTPClient streams the actual blob. Deliberately an interface, not a
	// *http.Client: production passes the *transport.Client itself so blob GETs
	// go through its Do, which self-heals a TLS connection that was negotiated
	// without a client certificate. Handed the bare embedded *http.Client
	// instead, blob pulls silently opt out of that recovery — they would 401
	// against the same poisoned pooled connection every other call recovers
	// from, and (worse) a poisoned connection checked out here during another
	// goroutine's purge can be drained and re-pooled, weakening the guarantee
	// for everyone. *http.Client still satisfies this, so tests keep passing
	// httptest's client unchanged.
	HTTPClient interface {
		Do(*http.Request) (*http.Response, error)
	}
	// PlatformURL is the base URL for resolving relative download_url
	// values returned by the platform. Required when DownloadURL is
	// relative (the common case).
	PlatformURL string
	// Cache is the root cache directory (typically /persist/cache/modules).
	Cache string
}

// FetchManifest hits the platform endpoint and decodes the artifact
// metadata. Returns an error when the module has no published version.
func (p *Puller) FetchManifest(moduleID string) (*ModuleArtifactRef, error) {
	if p == nil || p.Transport == nil {
		return nil, errors.New("oci.Puller: nil Transport")
	}
	if moduleID == "" {
		return nil, errors.New("oci.FetchManifest: empty moduleID")
	}
	resp, err := p.Transport.GetJSON(fmt.Sprintf("/api/v1/system/node_api/modules/%s/download", moduleID))
	if err != nil {
		return nil, fmt.Errorf("get manifest %s: %w", moduleID, err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("manifest %s status %d: %s", moduleID, resp.StatusCode, strings.TrimSpace(string(body)))
	}

	var env struct {
		Success bool `json:"success"`
		Data    struct {
			File struct {
				Name        string `json:"name"`
				Size        int64  `json:"size"`
				Checksum    string `json:"checksum"`
				DownloadURL string `json:"download_url"`
			} `json:"file"`
			OCI struct {
				Ref              string   `json:"ref"`
				Digest           string   `json:"digest"`
				CosignBundleB64  string   `json:"cosign_bundle_b64"`
				CosignPublicKeys []string `json:"cosign_public_keys"`
			} `json:"oci"`
		} `json:"data"`
	}
	if err := json.Unmarshal(body, &env); err != nil {
		return nil, fmt.Errorf("decode manifest: %w", err)
	}

	digest := strings.TrimPrefix(env.Data.OCI.Digest, "sha256:")
	if digest == "" {
		digest = env.Data.File.Checksum
	}
	if digest == "" {
		return nil, fmt.Errorf("manifest %s: no digest or checksum (module not published)", moduleID)
	}
	return &ModuleArtifactRef{
		ModuleID:         moduleID,
		OCIRef:           env.Data.OCI.Ref,
		Digest:           digest,
		DownloadURL:      env.Data.File.DownloadURL,
		Size:             env.Data.File.Size,
		Checksum:         env.Data.File.Checksum,
		CosignBundleB64:  env.Data.OCI.CosignBundleB64,
		CosignPublicKeys: env.Data.OCI.CosignPublicKeys,
	}, nil
}

// Pull downloads the artifact at ref into the cache directory.
// Returns the local paths to the erofs blob and the signature bundle.
// Idempotent: a cached blob matching ref.Digest is not re-fetched.
//
// The bundle is NOT fetched: when ref.CosignBundleB64 is set, Pull decodes it
// and writes it to bundlePath (0600, atomically) — on every call, including
// the cached-blob path, because a backfill can sign an artifact after a node
// cached its blob. When it is empty nothing is written, so bundlePath names a
// file that may not exist; a static-key Verifier refuses that by name. A
// bundle that does not decode fails the pull before any network I/O.
//
// Verification: sha256 streamed and compared to ref.Digest. Mismatch
// = tmp file deleted + error returned. Caller should also run cosign
// + fs-verity on the returned cfsPath.
func (p *Puller) Pull(ref *ModuleArtifactRef) (cfsPath, bundlePath string, err error) {
	if ref == nil {
		return "", "", errors.New("oci.Pull: nil ref")
	}
	if ref.Digest == "" {
		return "", "", errors.New("oci.Pull: empty digest (refusing to pull unverifiable artifact)")
	}
	if p.Cache == "" {
		return "", "", errors.New("oci.Pull: empty cache dir")
	}
	if err := os.MkdirAll(p.Cache, 0o755); err != nil {
		return "", "", fmt.Errorf("mkdir cache: %w", err)
	}

	digestFs := sanitizeDigest(ref.Digest)
	cfsPath = filepath.Join(p.Cache, digestFs+".erofs")
	bundlePath = filepath.Join(p.Cache, digestFs+".cosign-bundle")

	// Decode the bundle BEFORE any network I/O so a malformed one leaves no
	// partial state, and write it before the blob so a crash between the two
	// cannot leave a fresh blob beside a stale bundle. Writing on the
	// cached-blob path too is deliberate — see the doc comment.
	var bundle []byte
	if ref.CosignBundleB64 != "" {
		bundle, err = base64.StdEncoding.DecodeString(ref.CosignBundleB64)
		if err != nil {
			return "", "", fmt.Errorf("oci.Pull: ref %s carries an undecodable cosign bundle: %w", ref.ModuleID, err)
		}
	}
	if bundle != nil {
		if err := writeFileAtomic(bundlePath, bundle, 0o600); err != nil {
			return "", "", fmt.Errorf("oci.Pull: write cosign bundle: %w", err)
		}
	}

	// Idempotency: already cached at the right digest?
	if existing, err := readDigest(cfsPath); err == nil && strings.EqualFold(existing, strings.TrimPrefix(ref.Digest, "sha256:")) {
		return cfsPath, bundlePath, nil
	}

	url := absoluteURL(p.PlatformURL, ref.DownloadURL)
	if url == "" {
		return "", "", fmt.Errorf("oci.Pull: ref %s has neither download_url nor a usable PlatformURL", ref.ModuleID)
	}

	if err := p.streamToFile(url, cfsPath, ref); err != nil {
		return "", "", err
	}
	return cfsPath, bundlePath, nil
}

// streamToFile downloads url to a sibling .tmp file under path,
// computing sha256 inline. On success, atomically renames over path.
// On digest mismatch, deletes tmp and returns error.
func (p *Puller) streamToFile(url, path string, ref *ModuleArtifactRef) error {
	if p.HTTPClient == nil {
		return errors.New("oci.streamToFile: nil HTTPClient")
	}
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return fmt.Errorf("build request: %w", err)
	}
	resp, err := p.HTTPClient.Do(req)
	if err != nil {
		return fmt.Errorf("get %s: %w", url, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return fmt.Errorf("blob %s status %d: %s", url, resp.StatusCode, strings.TrimSpace(string(body)))
	}

	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, ".oci-pull-*")
	if err != nil {
		return fmt.Errorf("create temp: %w", err)
	}
	tmpName := tmp.Name()
	cleanup := func() { _ = os.Remove(tmpName) }

	hasher := sha256.New()
	written, err := io.Copy(io.MultiWriter(tmp, hasher), resp.Body)
	if err != nil {
		_ = tmp.Close()
		cleanup()
		return fmt.Errorf("stream blob: %w", err)
	}
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		cleanup()
		return err
	}
	if err := tmp.Close(); err != nil {
		cleanup()
		return err
	}

	if ref.Size > 0 && written != ref.Size {
		cleanup()
		return fmt.Errorf("blob %s size mismatch: got %d, expected %d", url, written, ref.Size)
	}

	got := hex.EncodeToString(hasher.Sum(nil))
	want := strings.TrimPrefix(ref.Digest, "sha256:")
	if !strings.EqualFold(got, want) {
		cleanup()
		return fmt.Errorf("blob %s digest mismatch: got %s, expected %s", url, got, want)
	}

	if err := os.Rename(tmpName, path); err != nil {
		cleanup()
		return fmt.Errorf("rename %s -> %s: %w", tmpName, path, err)
	}
	_ = os.Chmod(path, 0o644)
	return nil
}

// writeFileAtomic writes data to a temp sibling and renames it over path, so
// a reader (cosign) never sees a torn bundle.
func writeFileAtomic(path string, data []byte, perm os.FileMode) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), ".oci-bundle-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	cleanup := func() { _ = os.Remove(tmpName) }
	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		cleanup()
		return err
	}
	if err := tmp.Chmod(perm); err != nil {
		_ = tmp.Close()
		cleanup()
		return err
	}
	if err := tmp.Close(); err != nil {
		cleanup()
		return err
	}
	if err := os.Rename(tmpName, path); err != nil {
		cleanup()
		return err
	}
	return nil
}

// readDigest hashes the existing file at path. Returns the empty
// string + error when the file doesn't exist or is unreadable. Used
// for the idempotent "already cached at this digest" check.
func readDigest(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	hasher := sha256.New()
	if _, err := io.Copy(hasher, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(hasher.Sum(nil)), nil
}

// absoluteURL returns urlPath unchanged if absolute; otherwise joins
// it under base. Returns empty when neither base nor urlPath is set.
func absoluteURL(base, urlPath string) string {
	if urlPath == "" {
		return ""
	}
	if strings.HasPrefix(urlPath, "http://") || strings.HasPrefix(urlPath, "https://") {
		return urlPath
	}
	if base == "" {
		return ""
	}
	if !strings.HasPrefix(urlPath, "/") {
		urlPath = "/" + urlPath
	}
	return strings.TrimRight(base, "/") + urlPath
}

// sanitizeDigest replaces characters that are unsafe in filesystem
// paths. OCI digests are typically "sha256:abc..."; the colon is
// fine on Linux but trips up some tools when unquoted, so substitute
// underscore. MUST match mount.Layout's identically-named function
// (see internal/mount/layout.go) so the pull-step's output filename
// matches the mount-step's lookup filename — `sha256:abc...` becomes
// `sha256_abc...`, NOT `abc...`. An earlier version stripped the
// `sha256:` prefix before substitution, which produced bare-hex
// filenames the mount step couldn't find.
func sanitizeDigest(d string) string {
	out := make([]byte, 0, len(d))
	for _, c := range []byte(d) {
		switch {
		case c == ':' || c == '/' || c == ' ':
			out = append(out, '_')
		default:
			out = append(out, c)
		}
	}
	return string(out)
}
