package identity

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"sync/atomic"
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

	reads int32 // file reads performed (tests: one per Resolve)
}

func (s *BootKeyStrategy) Name() string { return "boot-key" }

// bootSnap is the BOOT file read ONCE per Resolve and shared by the gate,
// DiscoverPin and Discover, so the three views cannot disagree (no TOCTOU).
type bootSnap struct {
	once sync.Once
	id   *Identity
	err  error
}

type bootSnapKey struct{ s *BootKeyStrategy }

// withBootSnapshot arms ctx so every read of s within one Resolve is shared.
func withBootSnapshot(ctx context.Context, s *BootKeyStrategy) context.Context {
	return context.WithValue(ctx, bootSnapKey{s}, &bootSnap{})
}

// read returns the parsed BOOT file. ErrNotFound means there is no file (or no
// SERVER). EVERY other failure is a terminal refusal: an unreadable, corrupt or
// refused BOOT file must fail closed, never read as "absent" (which would make
// metadata and the stick eligible and drop the BOOT pin). A KEY with no ID is a
// dead end and is refused explicitly.
func (s *BootKeyStrategy) read(ctx context.Context) (*Identity, error) {
	load := func() (*Identity, error) {
		atomic.AddInt32(&s.reads, 1)
		id, err := (&BootIdentityStrategy{Path: s.Path}).Discover(ctx)
		if err != nil {
			if errors.Is(err, ErrNotFound) || errors.Is(err, ErrProvisionRefused) {
				return nil, err
			}
			return nil, fmt.Errorf("%w: BOOT identity.cfg unreadable: %v", ErrProvisionRefused, err)
		}
		if id != nil && id.BootstrapToken != "" && id.InstanceUUID == "" {
			return nil, fmt.Errorf("%w: BOOT identity.cfg holds a KEY but no ID; nothing can enrol with it", ErrProvisionRefused)
		}
		return id, nil
	}
	if sn, ok := ctx.Value(bootSnapKey{s}).(*bootSnap); ok {
		sn.once.Do(func() { sn.id, sn.err = load() })
		return sn.id, sn.err
	}
	return load()
}

// Discover returns the BOOT identity only when it holds a complete key.
func (s *BootKeyStrategy) Discover(ctx context.Context) (*Identity, error) {
	id, err := s.read(ctx)
	if err != nil {
		return nil, err
	}
	if id == nil || id.InstanceUUID == "" || id.BootstrapToken == "" || id.PlatformURL == "" {
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

// bootGate is what the BOOT file says about which other sources are eligible.
type bootGate struct {
	hasKey bool   // a complete key: metadata and the media scan are ineligible
	pin    string // a pin on a keyless (claim) BOOT file
	exists bool   // the file holds a usable identity.cfg (SERVER at least)
}

// gate reads the BOOT file for the resolver's eligibility decisions. A refused
// or unreadable file is returned as the terminal refusal it is, so nothing
// earlier (metadata, the stick) is consulted around it.
func (s *BootKeyStrategy) gate(ctx context.Context) (bootGate, error) {
	id, err := s.read(ctx)
	if err != nil {
		if errors.Is(err, ErrNotFound) {
			return bootGate{}, nil
		}
		return bootGate{}, err
	}
	if id == nil {
		return bootGate{}, nil
	}
	return bootGate{
		exists: true,
		hasKey: id.InstanceUUID != "" && id.BootstrapToken != "" && id.PlatformURL != "",
		pin:    id.CAFingerprint,
	}, nil
}
