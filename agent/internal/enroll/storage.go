package enroll

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"syscall"
)

// Two filesystem layouts host the agent's mTLS material:
//
//   - PKIDirInitramfs lives under /persist (a separate tmpfs mounted by
//     the initramfs's persist.mount unit and rbind-mounted into /sysroot
//     during prepare-root). The pivot_root design counts on this path
//     surviving the initramfs→pivot transition.
//   - PKIDirFHS is the conventional FHS path for cloud-VM hosts that
//     don't have /persist mounted (e.g. ProxmoxProvider's file-fallback
//     spawn path; Vultr/AWS/GCP cutovers).
//
// New code should call ResolveDefaultPKIDir() instead of hardcoding
// either constant — that way callers stay coherent across both layouts.
// PKIDir remains as a back-compat alias for the initramfs path so older
// references compile unchanged.
const (
	PKIDirInitramfs = "/persist/var/lib/powernode/pki"
	PKIDirFHS       = "/var/lib/powernode/pki"
	PKIDir          = PKIDirInitramfs // legacy alias — prefer ResolveDefaultPKIDir()
)

// ResolveDefaultPKIDir returns the PKI directory appropriate for the
// current filesystem layout. Picks the persist-layer path when /persist
// is its own mount (the initramfs mounts a dedicated /persist tmpfs, and
// prepare-root rbind-mounts it forward across switch_root — so it's a
// distinct mount in both the initramfs and post-pivot contexts),
// otherwise falls back to the FHS path for cloud-VM hosts with no
// /persist mount.
//
// The signal is /persist being a MOUNT, not the leaf /persist/var/lib/
// powernode directory pre-existing: on a virgin /persist tmpfs that leaf
// doesn't exist until federation-accept's enroll.Save creates it, so the
// old dirExists(leaf) check was chicken-and-egg — it resolved to the FHS
// path on first boot, federation-accept wrote the cert there, and the
// mount-gate (powernode-mount.service waits on /persist/var/lib/powernode/
// pki/node.crt) never fired, so the node never pivoted and fell into the
// anonymous claim loop. Testing the mount itself is stable from boot.
func ResolveDefaultPKIDir() string {
	if isDistinctMount("/persist") {
		return PKIDirInitramfs
	}
	return PKIDirFHS
}

// ResolveDefaultPKIPaths is the canonical-paths wrapper around
// ResolveDefaultPKIDir — saves callers from a two-step dance.
func ResolveDefaultPKIPaths() PKIPaths {
	return PathsUnder(ResolveDefaultPKIDir())
}

// isDistinctMount reports whether path is the root of its own mount — it
// sits on a different filesystem than its parent directory. Comparing
// st_dev against the parent is a cheap, dependency-free mount test that
// needs no /proc parse or shelling out; an rbind target inherits its
// source's device number, so a forward-bound /persist reads as distinct
// post-pivot too. A missing path (no /persist at all) reports false.
func isDistinctMount(path string) bool {
	fi, err := os.Stat(path)
	if err != nil {
		return false
	}
	parent, err := os.Stat(filepath.Dir(path))
	if err != nil {
		return false
	}
	st, ok := fi.Sys().(*syscall.Stat_t)
	pst, pok := parent.Sys().(*syscall.Stat_t)
	if !ok || !pok {
		return false
	}
	return st.Dev != pst.Dev
}

// PKIPaths are the canonical filenames within PKIDir.
type PKIPaths struct {
	Dir      string
	Key      string // private key (PEM)
	Cert     string // leaf cert (PEM)
	CAChain  string // platform's issuing chain (PEM)
	CABundle string // platform's TLS verification chain (PEM, from boot identity)
	Meta     string // small JSON sidecar with InstanceID, NotAfter, etc.
}

func PathsUnder(dir string) PKIPaths {
	return PKIPaths{
		Dir:      dir,
		Key:      filepath.Join(dir, "node.key"),
		Cert:     filepath.Join(dir, "node.crt"),
		CAChain:  filepath.Join(dir, "ca-chain.crt"),
		CABundle: filepath.Join(dir, "ca-bundle.crt"),
		Meta:     filepath.Join(dir, "meta.json"),
	}
}

// Save writes the EnrolledIdentity to disk. Files are written with
// restrictive modes (0600 for key, 0644 for certs). Metadata is written
// as JSON for cheap reads from other agent subcommands.
func Save(id *EnrolledIdentity, paths PKIPaths) error {
	if id == nil || id.Keypair == nil {
		return errors.New("Save: nil identity or keypair")
	}
	if err := os.MkdirAll(paths.Dir, 0o700); err != nil {
		return fmt.Errorf("mkdir %s: %w", paths.Dir, err)
	}

	keyPEM, err := id.Keypair.PrivatePEM()
	if err != nil {
		return fmt.Errorf("encode private key: %w", err)
	}

	if err := writeFileAtomic(paths.Key, keyPEM, 0o600); err != nil {
		return err
	}
	if err := writeFileAtomic(paths.Cert, id.CertPEM, 0o644); err != nil {
		return err
	}
	if err := writeFileAtomic(paths.CAChain, id.CAChainPEM, 0o644); err != nil {
		return err
	}
	if len(id.CABundlePEM) > 0 {
		if err := writeFileAtomic(paths.CABundle, id.CABundlePEM, 0o644); err != nil {
			return err
		}
	}

	meta := fmt.Sprintf(
		"{\"instance_id\":%q,\"mtls_subject\":%q,\"certificate_id\":%q,\"not_after\":%q,\"platform_url\":%q}\n",
		id.InstanceID, id.MTLSSubject, id.CertificateID, id.NotAfter.UTC().Format("2006-01-02T15:04:05Z"), id.PlatformURL,
	)
	return writeFileAtomic(paths.Meta, []byte(meta), 0o644)
}

// ReadPlatformURL returns the control-plane URL persisted in the PKI
// meta.json (written by Save at enroll time), or "" if absent/unreadable.
// It lets the post-pivot service adopt an already-enrolled on-disk identity
// without running the discovery resolver — whose ClaimStrategy would
// otherwise block forever on a spawn that already holds a valid cert.
func ReadPlatformURL(paths PKIPaths) string {
	data, err := os.ReadFile(paths.Meta)
	if err != nil {
		return ""
	}
	// Flat single-line JSON — a targeted substring scan avoids pulling
	// encoding/json onto the boot path (same rationale as readInstanceID).
	// URLs contain no `"`, so extract-until-next-quote is unambiguous.
	marker := []byte(`"platform_url":"`)
	i := bytes.Index(data, marker)
	if i < 0 {
		return ""
	}
	rest := data[i+len(marker):]
	end := bytes.IndexByte(rest, '"')
	if end < 0 {
		return ""
	}
	return string(rest[:end])
}

// writeFileAtomic writes via tmp + rename so a crash mid-write doesn't
// leave a half-written file. Sets the requested mode on the rename target.
func writeFileAtomic(path string, data []byte, mode os.FileMode) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), filepath.Base(path)+".tmp.*")
	if err != nil {
		return fmt.Errorf("temp file for %s: %w", path, err)
	}
	tmpName := tmp.Name()
	defer func() {
		_ = os.Remove(tmpName) // best-effort cleanup if rename never happens
	}()

	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		return fmt.Errorf("write %s: %w", path, err)
	}
	if err := tmp.Chmod(mode); err != nil {
		_ = tmp.Close()
		return fmt.Errorf("chmod %s: %w", path, err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("close %s: %w", path, err)
	}
	return os.Rename(tmpName, path)
}
