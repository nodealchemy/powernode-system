package enroll

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

// PKIDir is the canonical on-node location for the agent's mTLS material.
// Lives under /persist/var (the bind-mounted persistent layer per Golden
// Eclipse hybrid upper-layer design) so it survives reboots while the
// rest of root stays ephemeral.
const PKIDir = "/persist/var/lib/powernode/pki"

// PKIPaths are the canonical filenames within PKIDir.
type PKIPaths struct {
	Dir     string
	Key     string // private key (PEM)
	Cert    string // leaf cert (PEM)
	CAChain string // platform's issuing chain (PEM)
	CABundle string // platform's TLS verification chain (PEM, from boot identity)
	Meta    string // small JSON sidecar with InstanceID, NotAfter, etc.
}

// DefaultPKIPaths returns the canonical paths under PKIDir.
func DefaultPKIPaths() PKIPaths {
	return PathsUnder(PKIDir)
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
		"{\"instance_id\":%q,\"mtls_subject\":%q,\"certificate_id\":%q,\"not_after\":%q}\n",
		id.InstanceID, id.MTLSSubject, id.CertificateID, id.NotAfter.UTC().Format("2006-01-02T15:04:05Z"),
	)
	return writeFileAtomic(paths.Meta, []byte(meta), 0o644)
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
