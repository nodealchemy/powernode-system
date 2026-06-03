// registry.go — the skills this instance OFFERS to peers (the tools/list +
// tools/call surface of the A2A MCP server).

package a2a

import (
	"encoding/json"
	"fmt"
	"sort"
	"sync"
)

// SkillHandler executes a skill given its JSON arguments, returning a
// JSON-serializable result (or an error, surfaced as an MCP isError result).
type SkillHandler func(args json.RawMessage) (any, error)

type skillEntry struct {
	description string
	inputSchema map[string]any
	handler     SkillHandler
}

// Registry holds the offered skills. Safe for concurrent use.
type Registry struct {
	mu     sync.RWMutex
	skills map[string]skillEntry
}

func NewRegistry() *Registry {
	return &Registry{skills: make(map[string]skillEntry)}
}

// Register adds/replaces a skill. inputSchema is the MCP JSON Schema for the
// tool's arguments (nil -> a permissive object schema).
func (r *Registry) Register(name, description string, inputSchema map[string]any, h SkillHandler) {
	r.mu.Lock()
	r.skills[name] = skillEntry{description: description, inputSchema: inputSchema, handler: h}
	r.mu.Unlock()
}

// ToolSpec is an MCP tools/list entry.
type ToolSpec struct {
	Name        string         `json:"name"`
	Description string         `json:"description"`
	InputSchema map[string]any `json:"inputSchema"`
}

// List returns the offered tools, sorted by name for deterministic output.
func (r *Registry) List() []ToolSpec {
	r.mu.RLock()
	defer r.mu.RUnlock()
	out := make([]ToolSpec, 0, len(r.skills))
	for name, e := range r.skills {
		schema := e.inputSchema
		if schema == nil {
			schema = map[string]any{"type": "object"}
		}
		out = append(out, ToolSpec{Name: name, Description: e.description, InputSchema: schema})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

// Has reports whether a skill is registered.
func (r *Registry) Has(name string) bool {
	r.mu.RLock()
	defer r.mu.RUnlock()
	_, ok := r.skills[name]
	return ok
}

// Names returns the registered skill names (for announce/declared_skills).
func (r *Registry) Names() []string {
	r.mu.RLock()
	defer r.mu.RUnlock()
	out := make([]string, 0, len(r.skills))
	for name := range r.skills {
		out = append(out, name)
	}
	sort.Strings(out)
	return out
}

// Call dispatches to the skill handler.
func (r *Registry) Call(name string, args json.RawMessage) (any, error) {
	r.mu.RLock()
	e, ok := r.skills[name]
	r.mu.RUnlock()
	if !ok {
		return nil, fmt.Errorf("unknown skill %q", name)
	}
	return e.handler(args)
}

// RegisterPing installs the built-in "ping" skill — echoes back
// {pong:true, echo:<args>}. Used for liveness + the A2A smoke.
func (r *Registry) RegisterPing() {
	r.Register("ping", "Liveness echo — returns {pong:true, echo:<args>}",
		map[string]any{"type": "object"},
		func(args json.RawMessage) (any, error) {
			var v any
			if len(args) > 0 {
				_ = json.Unmarshal(args, &v)
			}
			return map[string]any{"pong": true, "echo": v}, nil
		})
}
