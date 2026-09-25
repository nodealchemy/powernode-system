package manifest

import (
	"bytes"
	"encoding/json"
)

// ServiceCapabilities is a service's own `capabilities:` key, carrying
// PRESENCE rather than just a list (IMP-caef5c00d63f).
//
// The module's security.capabilities is a CEILING for every unit the module
// owns. A service that declares no key inherits the whole ceiling; a service
// that declares one gets exactly that set, which must be a subset of the
// ceiling — and an explicit [] means ZERO. "Absent" and "empty" are therefore
// different instructions, and nothing here decides between them by length:
// a length check would read the non-root rails unit's [] as "declared
// nothing" and hand it rails-setup's CHOWN/FOWNER/DAC_OVERRIDE.
//
// Presence travels in Declared, set by UnmarshalJSON from the key itself, and
// survives a re-marshal: the manifest cache (writeCache / LoadFromDisk)
// round-trips through encoding/json, and the []string this replaced was
// tagged omitempty, so a declared [] was dropped on write and read back as
// absent — "zero" widened to "the whole ceiling" on the next cache-served
// reconcile.
type ServiceCapabilities struct {
	// Declared is true when the service carried a non-null capabilities key.
	Declared bool
	// Names is the declared set, as written. Meaningless when !Declared.
	Names []string
}

// IsZero drives the `omitzero` tag: an undeclared set is omitted from the
// wire form exactly as before, so a service with no key marshals (and
// ServicesHash-es) byte-identically to the old omitempty []string. A declared
// set — including [] — is not zero and is always written.
func (c ServiceCapabilities) IsZero() bool { return !c.Declared }

// MarshalJSON writes a declared set as a JSON array, [] included. An
// undeclared set is normally omitted by omitzero before this runs; if it is
// marshaled directly it is null, which UnmarshalJSON reads back as undeclared.
func (c ServiceCapabilities) MarshalJSON() ([]byte, error) {
	if !c.Declared {
		return []byte("null"), nil
	}
	if c.Names == nil {
		return []byte("[]"), nil
	}
	return json.Marshal(c.Names)
}

// UnmarshalJSON runs only when the key is present. An explicit null means the
// same as an absent key — stage 1 (IMP-074fcd68284f) stores SQL NULL for
// "the manifest omitted the key", and a serializer may emit it as null.
func (c *ServiceCapabilities) UnmarshalJSON(b []byte) error {
	if bytes.Equal(bytes.TrimSpace(b), []byte("null")) {
		*c = ServiceCapabilities{}
		return nil
	}
	var names []string
	if err := json.Unmarshal(b, &names); err != nil {
		return err
	}
	if names == nil {
		names = []string{}
	}
	*c = ServiceCapabilities{Declared: true, Names: names}
	return nil
}
