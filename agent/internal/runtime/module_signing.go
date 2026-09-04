package runtime

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/verify"
)

// Module signature verification — node-side policy resolution and the trust
// anchor. The verifier itself (multi-key static cosign, audit wrapper, the
// mode ladder) lives in internal/verify; this file is the glue that decides
// WHICH verifier a module-mount site gets and WHERE its public keys come
// from. DEFAULT OFF: with nothing configured every site gets verify.AlwaysOK
// and none of the I/O below happens. See internal/verify/doc.go and
// docs/runbooks/module-signature-verification.md.

// ModuleSigningConfPath is the persisted operator opt-in, read by every
// site (service loop, CLI reconciler, boot composer). Under /persist so it
// survives switch_root and is present when the boot composer runs. KEY=VALUE
// lines: MODE=off|audit|runtime|all, KEYS=/path/a.pub:/path/b.pub. A var so
// tests can sandbox it.
var ModuleSigningConfPath = "/persist/etc/powernode/module-signing.conf"

// DefaultModuleSigningKeyCacheDir is where the platform's trusted-key list is
// cached when the operator pins no KEYS. Under /persist so a fallback boot with
// the platform unreachable still has the anchor it last saw.
var DefaultModuleSigningKeyCacheDir = "/persist/var/lib/powernode/module-signing/platform-keys"

const (
	moduleSigningModeEnv = "POWERNODE_MODULE_SIGNING_MODE"
	moduleSigningKeysEnv = "POWERNODE_MODULE_SIGNING_KEYS"
	signingKeysPath      = "/api/v1/system/node_api/modules/signing_keys"
)

// LoadModuleSigningConfig resolves the node's module-signing policy from the
// conf file at confPath, then lets the environment (getenv) override each
// field: POWERNODE_MODULE_SIGNING_MODE and POWERNODE_MODULE_SIGNING_KEYS
// (colon- or comma-separated paths). An absent file and an empty environment
// yield the zero config, which is ModeOff. An unrecognised mode is an error —
// never coerced to off (a bypass) or to all (an outage).
func LoadModuleSigningConfig(getenv func(string) string, confPath string) (verify.ModuleSigningConfig, error) {
	var cfg verify.ModuleSigningConfig
	if getenv == nil {
		getenv = os.Getenv
	}
	if confPath == "" {
		confPath = ModuleSigningConfPath
	}
	if f, err := os.Open(confPath); err == nil {
		defer f.Close()
		sc := bufio.NewScanner(f)
		for sc.Scan() {
			line := strings.TrimSpace(sc.Text())
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}
			k, v, ok := strings.Cut(line, "=")
			if !ok {
				continue
			}
			v = strings.Trim(strings.TrimSpace(v), `"'`)
			switch strings.ToUpper(strings.TrimSpace(k)) {
			case "MODE":
				cfg.Mode = strings.ToLower(v)
			case "KEYS":
				cfg.KeyPaths = splitKeyList(v)
			}
		}
		if err := sc.Err(); err != nil {
			return cfg, fmt.Errorf("read %s: %w", confPath, err)
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return cfg, fmt.Errorf("open %s: %w", confPath, err)
	}
	if v := strings.TrimSpace(getenv(moduleSigningModeEnv)); v != "" {
		cfg.Mode = strings.ToLower(v)
	}
	if v := strings.TrimSpace(getenv(moduleSigningKeysEnv)); v != "" {
		cfg.KeyPaths = splitKeyList(v)
	}
	if err := cfg.Validate(); err != nil {
		return cfg, fmt.Errorf("module signing config (%s / %s): %w", confPath, moduleSigningModeEnv, err)
	}
	return cfg, nil
}

func splitKeyList(v string) []string {
	var out []string
	for _, p := range strings.FieldsFunc(v, func(r rune) bool { return r == ':' || r == ',' }) {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}

// signingKeysClient is the slice of *transport.Client the trust-anchor fetch
// needs.
type signingKeysClient interface {
	GetJSON(path string) (*http.Response, error)
}

// ResolveModuleVerifier is what every module-mount construction site calls.
// It returns the Verifier for cfg at site, sourcing the trust anchor as:
//
//  1. cfg.KeyPaths, when the operator pinned keys — used as-is, no I/O.
//  2. Otherwise the platform's trusted-key list, fetched from
//     /node_api/modules/signing_keys and cached under keyCacheDir; on a
//     failed fetch the cached set from the last successful one is used and
//     the failure is reported under "verify:module_signing_keys".
//
// With no anchor from either source: an ENFORCING site refuses to construct
// (the service does not start, the CLI command fails, an `all`-mode boot
// composer refuses to compose — deliberately, an operator who enforced must
// hear about a missing anchor at once); a non-enforcing site (audit, or the
// boot composer under runtime) reports and degrades to AlwaysOK, because
// measurement must never brick a node.
//
// ModeOff returns AlwaysOK immediately with no I/O of any kind.
func ResolveModuleVerifier(cfg verify.ModuleSigningConfig, site verify.Site, client signingKeysClient, runner mount.Runner, keyCacheDir string, onError func(string, error)) (verify.Verifier, error) {
	if onError == nil {
		onError = func(string, error) {}
	}
	if err := cfg.Validate(); err != nil {
		return nil, err
	}
	if !cfg.Active() {
		return verify.AlwaysOK{}, nil
	}
	if keyCacheDir == "" {
		keyCacheDir = DefaultModuleSigningKeyCacheDir
	}
	keys := cfg.KeyPaths
	if len(keys) == 0 {
		fetched, err := fetchPlatformSigningKeys(client)
		if err == nil {
			keys, err = cachePlatformSigningKeys(keyCacheDir, fetched)
		}
		if err != nil {
			onError("verify:module_signing_keys", fmt.Errorf("refresh platform module-signing keys: %w (using the cached set, if any)", err))
			keys, _ = cachedPlatformSigningKeys(keyCacheDir)
		}
	}
	cfg.KeyPaths = keys
	v, err := verify.NewModuleVerifier(cfg, site, runner, onError)
	if err != nil && !cfg.Enforces(site) {
		// Measurement must never block: no anchor means nothing can be
		// measured here, which is itself the finding.
		onError("verify:module_signing", fmt.Errorf("module signing %s at %s degraded to no verification: %w", cfg.Mode, site, err))
		return verify.AlwaysOK{}, nil
	}
	return v, err
}

// fetchPlatformSigningKeys GETs the platform's trusted module-signing public
// keys. The list is the same one the server verifies against at ingest
// (System::ModuleSigningTrust.public_keys): the Vault-transit / local
// signing key it signs blobs with, plus any legacy static key.
func fetchPlatformSigningKeys(c signingKeysClient) ([]string, error) {
	if c == nil {
		return nil, errors.New("nil client")
	}
	resp, err := c.GetJSON(signingKeysPath)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("%s: status %d: %s", signingKeysPath, resp.StatusCode, strings.TrimSpace(string(body)))
	}
	var env struct {
		Data struct {
			Keys []string `json:"keys"`
		} `json:"data"`
	}
	if err := json.Unmarshal(body, &env); err != nil {
		return nil, fmt.Errorf("decode %s: %w", signingKeysPath, err)
	}
	var keys []string
	for _, k := range env.Data.Keys {
		if k = strings.TrimSpace(k); k != "" {
			keys = append(keys, k+"\n")
		}
	}
	if len(keys) == 0 {
		return nil, errors.New("platform serves no trusted module-signing public keys (system.module_signing.trusted_public_keys is empty)")
	}
	return keys, nil
}

// cachePlatformSigningKeys writes each PEM to dir as <sha256(pem)[:16]>.pub
// (content-addressed, so the set is stable and idempotent) and prunes any
// .pub the platform no longer trusts. Returns the sorted paths.
func cachePlatformSigningKeys(dir string, pems []string) ([]string, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	want := map[string]bool{}
	var paths []string
	for _, pem := range pems {
		sum := sha256.Sum256([]byte(pem))
		name := hex.EncodeToString(sum[:8]) + ".pub"
		p := filepath.Join(dir, name)
		want[name] = true
		if cur, err := os.ReadFile(p); err == nil && string(cur) == pem {
			paths = append(paths, p)
			continue
		}
		tmp := p + ".tmp"
		if err := os.WriteFile(tmp, []byte(pem), 0o644); err != nil {
			return nil, err
		}
		if err := os.Rename(tmp, p); err != nil {
			_ = os.Remove(tmp)
			return nil, err
		}
		paths = append(paths, p)
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".pub") && !want[e.Name()] {
			_ = os.Remove(filepath.Join(dir, e.Name()))
		}
	}
	sort.Strings(paths)
	return paths, nil
}

// cachedPlatformSigningKeys lists the .pub files a previous successful fetch
// left in dir. Empty (not an error) when there are none.
func cachedPlatformSigningKeys(dir string) ([]string, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, err
	}
	var paths []string
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".pub") {
			paths = append(paths, filepath.Join(dir, e.Name()))
		}
	}
	sort.Strings(paths)
	return paths, nil
}

// lkgCosignBundle extracts the platform's blob-signature bundle from an LKG
// entry's embedded manifest — the same hop lkgFsverityRoot makes for the
// fs-verity root. Empty when absent; an enforcing verifier then refuses the
// mount by name rather than silently passing it.
func lkgCosignBundle(m LKGModule) string {
	if len(m.Manifest) == 0 {
		return ""
	}
	var mf struct {
		CosignBundleB64 string `json:"cosign_bundle_b64"`
	}
	if err := json.Unmarshal(m.Manifest, &mf); err != nil {
		return ""
	}
	return mf.CosignBundleB64
}
