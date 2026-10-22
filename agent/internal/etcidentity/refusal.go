package etcidentity

import (
	"fmt"
	"log"
)

// Refusal reports a manifest (or Set) identity entry that was NOT rendered
// because it failed validation (IMP-01a0f109). Fail closed: the entry is
// skipped and reported, never written.
type Refusal struct {
	Kind         string // "user" or "group"
	Name         string
	SourceModule string // "" when refused at render time
	Reason       string
}

func (r Refusal) Error() string {
	src := r.SourceModule
	if src == "" {
		src = "render"
	}
	return fmt.Sprintf("refusing %s %q (source=%s): %s", r.Kind, r.Name, src, r.Reason)
}

// LogRefused receives every entry the renderer itself skips (the second,
// render-time gate). Callers report Collect-time refusals through their own
// OnError hook; this is the backstop for a Set that never went through
// Collect. A var so tests can observe it.
var LogRefused = func(r Refusal) { log.Printf("etcidentity: %s", r.Error()) }
