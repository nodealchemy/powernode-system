// Package oci pulls module artifacts to a local cache.
//
// Phase 1 rewrite: the agent fetches manifest metadata from the
// platform's /api/v1/system/node_api/modules/:id/download endpoint
// and streams the artifact bytes via the same mTLS transport. No
// `oras` shell dependency — keeps the static binary lean and
// auth-uniform with the rest of the agent.
//
// The platform's response carries either:
//   - oci_ref + digest — pulled directly from the OCI registry, OR
//   - download_url — a platform-proxied fallback when the OCI
//     registry is unreachable from the agent (typical in air-gapped
//     fleets).
//
// Reference: Golden Eclipse plan M2.D.5; M1 supply chain.
package oci

import (
	"crypto/sha256"
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
	ModuleID    string
	OCIRef      string // optional; when set, prefer the OCI registry path
	Digest      string // sha256 hex (without "sha256:" prefix); REQUIRED
	DownloadURL string // platform-proxied artifact URL (used when OCI unreachable)
	Size        int64
	Checksum    string // legacy checksum field (sha256 hex)
}

// Puller downloads OCI artifacts to a local cache.
type Puller struct {
	// Transport is used for the manifest GET (small JSON response).
	Transport Client
	// HTTPClient is used for the actual blob streaming. In production
	// this is the same *http.Client wrapped by *transport.Client; share
	// it so mTLS material is uniform across calls.
	HTTPClient *http.Client
	// PlatformURL is the base URL for resolving relative download_url
	// values returned by the platform. Required when DownloadURL is
	// relative (the common case).
	PlatformURL string
	// Cache is the root cache directory (typically /persist/cache/modules).
	Cache string
	// AuthHeader, when set, is added to every blob GET. Forwards the
	// instance JWT as Bearer when mTLS isn't terminated proxy-side.
	AuthHeader string
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
				Ref    string `json:"ref"`
				Digest string `json:"digest"`
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
		ModuleID:    moduleID,
		OCIRef:      env.Data.OCI.Ref,
		Digest:      digest,
		DownloadURL: env.Data.File.DownloadURL,
		Size:        env.Data.File.Size,
		Checksum:    env.Data.File.Checksum,
	}, nil
}

// Pull downloads the artifact at ref into the cache directory.
// Returns the local paths to the composefs blob and the (expected)
// signature bundle. Idempotent: cached file matching ref.Digest =
// no-op.
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
	cfsPath = filepath.Join(p.Cache, digestFs+".cfs")
	bundlePath = filepath.Join(p.Cache, digestFs+".cosign-bundle")

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
	if p.AuthHeader != "" {
		req.Header.Set("Authorization", p.AuthHeader)
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
// fine on Linux but trips up some tools when unquoted.
func sanitizeDigest(d string) string {
	d = strings.TrimPrefix(d, "sha256:")
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
