package runtime

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/nodealchemy/powernode-system/agent/internal/fsutil"
)

// PendingComposePath stages a module composition that has NOT yet been proven to
// boot. It is the missing middle rung between a live fetch and the frozen LKG.
//
// Why it exists: ComposeForPivot resolves the assigned-module set PRE-pivot, by
// fetching from the platform. On a SELF-HOSTED control plane the platform is the
// node itself, which is not running yet, so that fetch can never succeed. Every
// boot therefore falls back to the frozen LKG and reports from_lkg — and
// LKGCapturer refuses to promote on exactly that condition, so the LKG can never
// advance either. The node composes one frozen module set forever and no
// current_version change can ever reach it. Deleting the LKG to escape (the
// documented path) bricks it: nothing to fetch, nothing to fall back to.
//
// The fix mirrors the A/B boot slots this system already uses for the kernel:
// stage the new thing, try it ONCE with the known-good still underneath, and
// promote it only after it proves healthy.
//
//	live fetch  → use it                       (normal nodes, unchanged)
//	  ↓ fails
//	pending set → try once, counter-guarded    (self-hosted nodes get new modules)
//	  ↓ absent / exhausted / invalid
//	frozen LKG  → fall back                    (unchanged)
//
// The pending set is written POST-pivot by the running agent, which CAN reach
// the platform — that is the whole trick. It is consumed at most PendingMaxTries
// times: the counter is persisted BEFORE the compose that uses it, so a set that
// panics the node cannot retry forever. When a pending-composed boot passes the
// same health gate that guards the boot-slot bless, LKGCapturer promotes it to
// the frozen LKG, which is what finally lets the LKG advance.
const PendingComposePath = "/persist/var/lib/powernode/pending-compose.json"

// PendingMaxTries bounds how many boots may attempt an unproven composition
// before it is abandoned and the node falls back to the frozen LKG. One real
// attempt plus one margin: a set that fails to reach health twice is not going
// to on the third.
const PendingMaxTries = 2

// PendingCompose is a candidate module set awaiting proof. It reuses BootLKG's
// shape deliberately — same modules, same checksum contract, same validator — so
// a promoted pending set IS a valid LKG with no translation step to get wrong.
type PendingCompose struct {
	// Set is the candidate composition, in the frozen-LKG format.
	Set BootLKG `json:"set"`
	// StagedAt is when the running agent observed this desired set.
	StagedAt time.Time `json:"staged_at"`
	// Attempts counts boots that have composed from this set. Incremented and
	// persisted BEFORE the compose, never after: a set that hangs or panics
	// mid-boot must still burn its attempt, or it retries forever.
	Attempts int `json:"attempts"`
	// Reason is operator-facing context for why this was staged.
	Reason string `json:"reason,omitempty"`
}

// LoadPendingCompose reads the staged composition. os.ErrNotExist (wrapped) when
// absent, which is the normal case on a healthy node with nothing in flight.
func LoadPendingCompose(path string) (*PendingCompose, error) {
	body, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var p PendingCompose
	if err := json.Unmarshal(body, &p); err != nil {
		return nil, fmt.Errorf("decode pending-compose %s: %w", path, err)
	}
	return &p, nil
}

// WritePendingCompose atomically stages a candidate set, stamping the checksum
// through the same path a frozen LKG uses so the two can never disagree about
// what a valid module set looks like.
func WritePendingCompose(path string, p *PendingCompose) error {
	if p == nil {
		return errors.New("WritePendingCompose: nil")
	}
	if len(p.Set.Modules) == 0 {
		return errors.New("WritePendingCompose: refusing to stage an empty module set")
	}
	p.Set.SchemaVersion = bootLKGSchemaVersion
	sum, err := checksumModules(p.Set.Modules)
	if err != nil {
		return err
	}
	p.Set.Checksum = sum
	// AtomicWriteJSON does not mkdir; on a first boot nothing may have created
	// the survival dir yet (mirrors WriteBootLKG).
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("mkdir %s: %w", filepath.Dir(path), err)
	}
	return fsutil.AtomicWriteJSON(path, p, 0o600)
}

// ClearPendingCompose removes the staged set. Used once it has been promoted to
// the LKG, or abandoned after exhausting its attempts.
func ClearPendingCompose(path string) error {
	err := os.Remove(path)
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

// TakePendingCompose returns a staged set that is safe to compose from, having
// already burned one attempt against it. It returns nil (no error) whenever
// there is nothing usable — absent, exhausted, or failing validation — because
// every one of those is a normal "fall through to the LKG" outcome rather than a
// boot failure.
//
// The attempt is persisted BEFORE the caller composes. That ordering is the
// whole safety property: if the resulting boot never comes back, the count has
// already advanced on disk, so the next boot sees one fewer try and eventually
// stops offering it.
func TakePendingCompose(path string, cachePath func(digest string) string, onError func(string, error)) *PendingCompose {
	p, err := LoadPendingCompose(path)
	if err != nil {
		if !os.IsNotExist(err) && onError != nil {
			onError("compose:pending_unreadable", err)
		}
		return nil
	}
	if p.Attempts >= PendingMaxTries {
		if onError != nil {
			onError("compose:pending_exhausted", fmt.Errorf(
				"staged composition has used all %d attempts without proving healthy — falling back to the frozen LKG",
				PendingMaxTries))
		}
		return nil
	}
	// Validate with the frozen-LKG validator: schema, checksum, and every data
	// module's blob actually present in the cache. A staged set whose blobs were
	// never pulled would compose into a root that cannot mount.
	if err := ValidateBootLKG(&p.Set, cachePath); err != nil {
		if onError != nil {
			onError("compose:pending_invalid", err)
		}
		return nil
	}
	p.Attempts++
	if err := WritePendingCompose(path, p); err != nil {
		// Could not record the attempt. Refuse to use the set rather than risk an
		// unbounded retry loop on a node whose /persist is not writable.
		if onError != nil {
			onError("compose:pending_attempt_unrecorded", err)
		}
		return nil
	}
	return p
}
