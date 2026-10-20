package identity

import (
	"context"
	"errors"
)

// BootKeyStrategy is the BOOT identity.cfg KEY as an identity SOURCE (position
// 6 of the precedence order, identity.go): the /boot/identity.cfg of a device
// flashed from a per-instance image, when it carries a bootstrap token. It is
// ClaimStrategy's pass-through half split out, so the key can sit ahead of the
// console prompt while the claim POLL stays last.
//
// A BOOT file without a key (SERVER only, or SERVER+ID for claim-by-ID) is not
// a key: Discover returns ErrNotFound and the file stays claim material for
// ClaimStrategy. Its pin, though, is still a pin: the resolver asks for it via
// DiscoverPin whenever another source already supplied the key, so a
// ca_fingerprint here is enforced on every source.
type BootKeyStrategy struct {
	// Path defaults to /boot/identity.cfg.
	Path string
}

func (s *BootKeyStrategy) Name() string { return "boot-key" }

func (s *BootKeyStrategy) read(ctx context.Context) (*Identity, error) {
	return (&BootIdentityStrategy{Path: s.Path}).Discover(ctx)
}

// Discover returns the BOOT identity only when it holds a complete key.
func (s *BootKeyStrategy) Discover(ctx context.Context) (*Identity, error) {
	id, err := s.read(ctx)
	if err != nil {
		return nil, err
	}
	if id == nil || id.InstanceUUID == "" || id.BootstrapToken == "" {
		return nil, ErrNotFound
	}
	return id, nil
}

// DiscoverPin returns the BOOT file's ca_fingerprint, key or no key. A refused
// v1 document is returned as the terminal error it is.
func (s *BootKeyStrategy) DiscoverPin(ctx context.Context) (string, error) {
	id, err := s.read(ctx)
	if err != nil {
		if errors.Is(err, ErrNotFound) {
			return "", nil
		}
		return "", err
	}
	if id == nil {
		return "", nil
	}
	return id.CAFingerprint, nil
}
