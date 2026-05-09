package tasks

import (
	"fmt"
	"sync"
)

// Registry holds the agent's task command → handler bindings.
// Populated at startup by RegisterDefaults; the lookup path is
// read-mostly so a sync.RWMutex keeps the loop hot path lock-free.
type Registry struct {
	mu       sync.RWMutex
	handlers map[string]TaskHandler
}

// NewRegistry returns an empty registry.
func NewRegistry() *Registry {
	return &Registry{handlers: map[string]TaskHandler{}}
}

// Register binds command to h. Panics if command is already bound —
// duplicate registrations are bugs that should fail loud at startup,
// not silently with one binding shadowing another.
func (r *Registry) Register(command string, h TaskHandler) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if _, dup := r.handlers[command]; dup {
		panic("tasks.Registry: duplicate handler for command: " + command)
	}
	r.handlers[command] = h
}

// Lookup returns the handler bound to command, or (nil, false) when
// no binding exists. The loop reports "unknown_command:" + name as
// the failure reason for unknown commands.
func (r *Registry) Lookup(command string) (TaskHandler, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	h, ok := r.handlers[command]
	return h, ok
}

// Commands returns the list of bound command names. Used for
// startup logging so operators can see which commands the agent
// announces as supported.
func (r *Registry) Commands() []string {
	r.mu.RLock()
	defer r.mu.RUnlock()
	out := make([]string, 0, len(r.handlers))
	for cmd := range r.handlers {
		out = append(out, cmd)
	}
	return out
}

// String returns a human-readable summary for logging.
func (r *Registry) String() string {
	return fmt.Sprintf("tasks.Registry(%d commands)", len(r.handlers))
}
