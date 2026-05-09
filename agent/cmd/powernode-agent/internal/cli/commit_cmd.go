package cli

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// CommitOptions drives `powernode-agent commit <module-id>`. Default
// behavior is stage-only — capture the upper-dir delta to a local
// staging directory, print the path, and let the operator inspect
// before explicitly pushing. This is the legacy-footgun fix the
// plan calls out: legacy ipn shipped tarballs straight to the server
// with no review window.
type CommitOptions struct {
	ModuleID    string
	Changelog   string
	StageOnly   bool   // default true; --push <path> overrides
	PushPath    string // staged tarball to upload (use --push)
	AutoPush    bool   // capture + push in one step (skips review)
	ScanSecrets bool   // default ON when AutoPush, default OFF for stage-only
	JSON        bool
	PlatformURL string
	PKIDir      string
	Runner      mount.Runner
	// SourceRoot is what gets walked. Defaults to /sysroot in
	// production; tests set this to a temp dir.
	SourceRoot string
	// StagingRoot is where the staged tarball lands. Defaults to
	// /persist/var/lib/powernode/commits.
	StagingRoot string
}

// hardcodedDenyList is the agent's defense-in-depth against
// shipping secrets in module versions. ALWAYS applied in addition
// to the module's manifest mask + protected_spec.
var hardcodedDenyList = []string{
	"/etc/shadow",
	"/etc/shadow-",
	"/etc/gshadow",
	"/etc/gshadow-",
	"/etc/sudoers",
	"/etc/sudoers.d",
	"/etc/ssh/ssh_host_*_key",
	"/etc/ssh/ssh_host_*_key.pub",
	"/root/.ssh",
	"/persist/var/lib/powernode/pki",
	"/var/lib/cloud",
}

// secretPatterns are scanned in --scan-secrets mode. Each match
// short-circuits the commit with a list of offending paths.
var secretPatterns = []*regexp.Regexp{
	regexp.MustCompile(`-----BEGIN [A-Z ]*PRIVATE KEY-----`),
	regexp.MustCompile(`-----BEGIN OPENSSH PRIVATE KEY-----`),
	regexp.MustCompile(`AKIA[0-9A-Z]{16}`),                    // AWS access key id
	regexp.MustCompile(`(?i)aws_secret_access_key\s*=\s*\S+`), // AWS secret in INI
}

// RunCommit captures the upper-dir delta + stages or pushes.
func RunCommit(ctx context.Context, opts CommitOptions) (Result, error) {
	if opts.ModuleID == "" {
		return errResult("commit", ExitGeneric, "missing_module_id", errors.New("module-id required")),
			Errorf(ExitGeneric, "commit", "module-id required")
	}
	if opts.PushPath != "" {
		return runCommitPush(ctx, opts)
	}
	return runCommitCapture(ctx, opts)
}

// runCommitCapture is the staging path. Computes the delta, runs
// optional secret scan, writes the tar.zst + metadata to staging,
// and either stops (default) or auto-pushes (--auto-push).
func runCommitCapture(ctx context.Context, opts CommitOptions) (Result, error) {
	if opts.SourceRoot == "" {
		opts.SourceRoot = "/sysroot"
	}
	if opts.StagingRoot == "" {
		opts.StagingRoot = "/persist/var/lib/powernode/commits"
	}
	if opts.Runner == nil {
		opts.Runner = mount.ExecRunner{}
	}
	if opts.AutoPush {
		opts.ScanSecrets = true
	}

	cctx, err := BuildContext(opts.PlatformURL, opts.PKIDir)
	if err != nil {
		return errResult("commit", ExitPlatformUnreached, "build_context", err),
			Errorf(ExitPlatformUnreached, "commit", "%w", err)
	}

	mf, err := manifest.LoadOrFetch(cctx.Transport, manifest.DefaultRoot, opts.ModuleID, 0)
	if err != nil {
		return errResult("commit", ExitGeneric, "load_manifest", err),
			Errorf(ExitGeneric, "commit:load_manifest", "%w", err)
	}

	if len(mf.Mask)+len(mf.ProtectedSpec) == 0 {
		return errResult("commit", ExitRefused, "empty_effective_mask",
				errors.New("module has empty mask + protected_spec; refuse (likely misconfig)")),
			Errorf(ExitRefused, "commit:empty_effective_mask",
				"module %s has no mask or protected_spec entries (likely misconfig)", opts.ModuleID)
	}

	stagingDir := filepath.Join(opts.StagingRoot, opts.ModuleID)
	if err := os.MkdirAll(stagingDir, 0o755); err != nil {
		return errResult("commit", ExitGeneric, "mkdir_staging", err),
			Errorf(ExitGeneric, "commit:mkdir_staging", "%w", err)
	}

	timestamp := time.Now().UTC().Format("20060102T150405Z")
	stagePath := filepath.Join(stagingDir, timestamp+".tar.zst")
	metaPath := filepath.Join(stagingDir, timestamp+".metadata.json")

	filterFile, err := writeRsyncFilter(stagingDir, mf, hardcodedDenyList)
	if err != nil {
		return errResult("commit", ExitGeneric, "write_filter", err),
			Errorf(ExitGeneric, "commit:write_filter", "%w", err)
	}
	defer os.Remove(filterFile)

	// Build rsync command: capture matching paths to a working dir,
	// then tar+zstd it. Using --files-from would require a different
	// shape; here we use --include-from + --exclude-from-style filter.
	workDir, err := os.MkdirTemp(stagingDir, "work-*")
	if err != nil {
		return errResult("commit", ExitGeneric, "mktmp", err),
			Errorf(ExitGeneric, "commit:mktmp", "%w", err)
	}
	defer os.RemoveAll(workDir)

	rsyncErr := opts.Runner.Run(ctx, "rsync", "-a",
		"--filter=. "+filterFile, opts.SourceRoot+"/", workDir+"/")
	if rsyncErr != nil {
		return errResult("commit", ExitGeneric, "rsync", rsyncErr),
			Errorf(ExitGeneric, "commit:rsync", "%w", rsyncErr)
	}

	if opts.ScanSecrets {
		if hits := scanSecrets(workDir); len(hits) > 0 {
			return errResult("commit", ExitRefused, "secret_scan",
					fmt.Errorf("secrets detected in %d paths", len(hits))),
				Errorf(ExitRefused, "commit:secret_scan",
					"refusing — secrets detected in: %s", strings.Join(truncate(hits, 5), ", "))
		}
	}

	if err := opts.Runner.Run(ctx, "tar",
		"--use-compress-program=zstd", "-cf", stagePath, "-C", workDir, "."); err != nil {
		return errResult("commit", ExitGeneric, "tar", err),
			Errorf(ExitGeneric, "commit:tar", "%w", err)
	}

	digest, err := fileSha256(stagePath)
	if err != nil {
		return errResult("commit", ExitGeneric, "digest", err),
			Errorf(ExitGeneric, "commit:digest", "%w", err)
	}

	meta := map[string]any{
		"module_id":    opts.ModuleID,
		"changelog":    opts.Changelog,
		"timestamp":    timestamp,
		"sha256":       digest,
		"staged_path":  stagePath,
	}
	metaBody, _ := json.MarshalIndent(meta, "", "  ")
	if err := os.WriteFile(metaPath, metaBody, 0o644); err != nil {
		return errResult("commit", ExitGeneric, "write_meta", err),
			Errorf(ExitGeneric, "commit:write_meta", "%w", err)
	}

	res := Result{
		Command: "commit",
		Status:  "ok",
		Details: map[string]any{
			"module_id":     opts.ModuleID,
			"staged_path":   stagePath,
			"metadata_path": metaPath,
			"sha256":        digest,
			"next_step":     "powernode-agent commit " + opts.ModuleID + " --push " + stagePath,
		},
	}

	if opts.AutoPush {
		opts.PushPath = stagePath
		return runCommitPush(ctx, opts)
	}
	return res, nil
}

// runCommitPush uploads a previously-staged tarball to the platform.
// Multipart POST to /api/v1/system/node_api/modules/:id/versions.
func runCommitPush(ctx context.Context, opts CommitOptions) (Result, error) {
	st, err := os.Stat(opts.PushPath)
	if err != nil {
		return errResult("commit", ExitGeneric, "stat_push_path", err),
			Errorf(ExitGeneric, "commit:stat_push_path", "%w", err)
	}
	if st.IsDir() {
		return errResult("commit", ExitGeneric, "push_path_is_dir",
				errors.New("push path is a directory; pass the .tar.zst file")),
			Errorf(ExitGeneric, "commit:push_path_is_dir",
				"%s is a directory; pass the .tar.zst file", opts.PushPath)
	}

	body, err := os.ReadFile(opts.PushPath)
	if err != nil {
		return errResult("commit", ExitGeneric, "read_push", err),
			Errorf(ExitGeneric, "commit:read_push", "%w", err)
	}
	digest, err := fileSha256(opts.PushPath)
	if err != nil {
		return errResult("commit", ExitGeneric, "digest", err),
			Errorf(ExitGeneric, "commit:digest", "%w", err)
	}

	cctx, err := BuildContext(opts.PlatformURL, opts.PKIDir)
	if err != nil {
		return errResult("commit", ExitPlatformUnreached, "build_context", err),
			Errorf(ExitPlatformUnreached, "commit", "%w", err)
	}

	uploadBody, _ := json.Marshal(map[string]any{
		"changelog":  opts.Changelog,
		"sha256":     digest,
		"size_bytes": st.Size(),
		"tar_b64":    encodeBase64(body),
	})
	resp, err := cctx.Transport.PostJSON(
		fmt.Sprintf("/api/v1/system/node_api/modules/%s/versions", opts.ModuleID),
		uploadBody,
	)
	if err != nil {
		return errResult("commit", ExitPlatformUnreached, "post", err),
			Errorf(ExitPlatformUnreached, "commit:post", "%w", err)
	}
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return errResult("commit", ExitGeneric, "post_status",
				fmt.Errorf("status %d: %s", resp.StatusCode, strings.TrimSpace(string(respBody)))),
			Errorf(ExitGeneric, "commit:post_status",
				"status %d: %s", resp.StatusCode, strings.TrimSpace(string(respBody)))
	}
	var env struct {
		Data struct {
			Version struct {
				ID            string `json:"id"`
				VersionNumber string `json:"version_number"`
			} `json:"version"`
		} `json:"data"`
	}
	json.Unmarshal(respBody, &env)

	return Result{
		Command: "commit",
		Status:  "ok",
		Details: map[string]any{
			"module_id":      opts.ModuleID,
			"pushed_path":    opts.PushPath,
			"sha256":         digest,
			"version_id":     env.Data.Version.ID,
			"version_number": env.Data.Version.VersionNumber,
		},
	}, nil
}

// writeRsyncFilter renders an rsync filter file from manifest entries
// + the hardcoded deny list. Returns the temp file path.
func writeRsyncFilter(dir string, mf *manifest.Manifest, deny []string) (string, error) {
	f, err := os.CreateTemp(dir, "filter-*")
	if err != nil {
		return "", err
	}
	defer f.Close()
	w := func(s string) { fmt.Fprintln(f, s) }
	for _, d := range deny {
		w("- " + d)
	}
	for _, m := range mf.Mask {
		w("- " + m)
	}
	for _, p := range mf.ProtectedSpec {
		w("- " + p)
	}
	for _, fs := range mf.FileSpec {
		w("+ " + fs)
	}
	w("- *")
	return f.Name(), nil
}

// scanSecrets walks the work tree and returns paths matching any
// pattern in secretPatterns. Bounded to first N hits to avoid
// runaway memory on a large delta.
func scanSecrets(root string) []string {
	const maxHits = 50
	var hits []string
	filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil || info == nil || info.IsDir() {
			return nil
		}
		if info.Size() > 4<<20 {
			return nil // skip large binaries
		}
		body, err := os.ReadFile(path)
		if err != nil {
			return nil
		}
		for _, pat := range secretPatterns {
			if pat.Match(body) {
				hits = append(hits, path)
				if len(hits) >= maxHits {
					return io.EOF
				}
				break
			}
		}
		return nil
	})
	return hits
}

func fileSha256(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

func encodeBase64(b []byte) string {
	const tbl = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	var out bytes.Buffer
	out.Grow(((len(b) + 2) / 3) * 4)
	for i := 0; i < len(b); i += 3 {
		var v uint32
		var pad int
		switch {
		case i+2 < len(b):
			v = uint32(b[i])<<16 | uint32(b[i+1])<<8 | uint32(b[i+2])
		case i+1 < len(b):
			v = uint32(b[i])<<16 | uint32(b[i+1])<<8
			pad = 1
		default:
			v = uint32(b[i]) << 16
			pad = 2
		}
		out.WriteByte(tbl[(v>>18)&0x3f])
		out.WriteByte(tbl[(v>>12)&0x3f])
		if pad < 2 {
			out.WriteByte(tbl[(v>>6)&0x3f])
		} else {
			out.WriteByte('=')
		}
		if pad < 1 {
			out.WriteByte(tbl[v&0x3f])
		} else {
			out.WriteByte('=')
		}
	}
	return out.String()
}

func truncate(s []string, n int) []string {
	if len(s) <= n {
		return s
	}
	return append(s[:n], "...")
}

// HTTPPostClient is the minimal interface used for the push path.
// transport.Client + transport.SwappableClient both satisfy it.
type HTTPPostClient interface {
	PostJSON(path string, body []byte) (*http.Response, error)
}
