package handlers

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"

	"github.com/nodealchemy/powernode-system/agent/internal/runtime/tasks"
	"github.com/nodealchemy/powernode-system/agent/internal/security"
	"github.com/nodealchemy/powernode-system/agent/internal/taskguard"
)

// UnitDropinHandler writes, or reverts, ONE runtime systemd drop-in for a unit
// this node's agent generated (IMP-9951cbf20bb0):
//
//	/run/systemd/system/<unit>.d/zz-operator-<name>.conf
//
// /run is tmpfs, so a reboot reverts it; the zz- prefix sorts it after every
// drop-in a module ships. A revert removes that one file and nothing else.
// Either way the handler then runs `systemctl daemon-reload` through the
// injected runner. It never restarts the unit: that is the separate, governed
// restart task.
//
// It replaces a root QGA printf into /run/systemd/system, and it must not be a
// root write primitive by another name. So, independently of the control
// plane's System::UnitDropinService (the agent must not assume the control
// plane is honest; see package taskguard):
//
//   - the unit must be one this node generated, checked by the restart
//     handler's validateUnit, and never the agent's own;
//   - the name is ^[a-z0-9-]{1,32}$, so the file name is fixed but for it;
//   - every directive is on a fixed allow-list with a strict value grammar,
//     and no key or value may carry a control character, a backslash, a
//     bracket, a double quote or a %-specifier: one newline in a value would
//     otherwise add an ExecStartPre= line. The file is rendered here from the
//     validated pairs under a single [Service] header;
//   - every allowed directive only LIMITS the unit: no Environment= (a name
//     denylist is incomplete by construction: LD_PRELOAD, NODE_OPTIONS,
//     BASH_ENV, PATH), capability lists must be a subset of the set this agent
//     rendered into the unit's capabilities.conf, and ReadWritePaths never
//     names this agent's own state or trust material;
//   - the write goes through an O_NOFOLLOW directory fd and a temp file in the
//     same directory, fsynced and renamed into place, so a symlink planted at
//     <unit>.d or at the target cannot redirect it and an error never leaves a
//     partial file.
//
// testdata/unit_dropin_cases.json is shared with the server's spec: the two
// allow-lists and the two renderers must give the same answers.
//
// Idempotent: re-applying rewrites the same bytes, and reverting a file that
// is not there reports "absent". Both reload.
type UnitDropinHandler struct {
	deps tasks.Dependencies
}

// RegisterUnitDropin binds the unit.dropin command.
func RegisterUnitDropin(r *tasks.Registry, deps tasks.Dependencies) {
	r.Register("unit.dropin", &UnitDropinHandler{deps: deps})
}

const (
	// dropinCanonicalRoot is where the drop-in lives on a node, and what the
	// result reports. dropinRoot is the seam a test points at a sandbox.
	dropinCanonicalRoot = "/run/systemd/system"
	dropinFilePrefix    = "zz-operator-"
	dropinMaxDirectives = 32
	dropinMaxKeyLen     = 64
	dropinMaxValueLen   = 1024
	dropinMaxPaths      = 16
	// Same prefix System::UnitRestartService refuses: the agent's own unit and
	// its variants.
	dropinAgentUnitPrefix = "powernode-agent"
)

var dropinRoot = dropinCanonicalRoot

// SetDropinRootForTest points the handler at a sandbox standing in for
// /run/systemd/system, returning a restore func.
func SetDropinRootForTest(dir string) (restore func()) {
	prev := dropinRoot
	dropinRoot = dir
	return func() { dropinRoot = prev }
}

// dropinFault, when set, is consulted at each stage of the write ("write",
// "fsync", "rename") and its error aborts the write there. Nil in production.
var dropinFault func(stage string) error

// SetDropinFaultForTest installs a fault injector, returning a restore func.
func SetDropinFaultForTest(fn func(stage string) error) (restore func()) {
	prev := dropinFault
	dropinFault = fn
	return func() { dropinFault = prev }
}

func dropinCheckFault(stage string) error {
	if dropinFault == nil {
		return nil
	}
	return dropinFault(stage)
}

var (
	dropinNameShape = regexp.MustCompile(`^[a-z0-9-]{1,32}$`)
	dropinLimitPart = regexp.MustCompile(`^(?:infinity|[1-9][0-9]{0,9})$`)
	dropinPathShape = regexp.MustCompile(`^(?:/[A-Za-z0-9._-]+)+$`)

	dropinGrammars = map[string]*regexp.Regexp{
		"MemoryMax": regexp.MustCompile(`^(?:infinity|[1-9][0-9]{0,14}[KMGT]?|(?:[1-9][0-9]?|100)%)$`),
		"CPUQuota":  regexp.MustCompile(`^[1-9][0-9]{0,4}%$`),
		"TasksMax":  regexp.MustCompile(`^(?:infinity|[1-9][0-9]{0,6}|(?:[1-9][0-9]?|100)%)$`),
	}

	// The allow-list. MUST mirror System::UnitDropinService::ALLOWED_DIRECTIVES.
	dropinAllowed = map[string]bool{
		"MemoryMax": true, "CPUQuota": true, "TasksMax": true, "LimitNOFILE": true,
		"AmbientCapabilities": true, "CapabilityBoundingSet": true, "ReadWritePaths": true,
	}
	// Rendered as a reset line then the list: a drop-in's capability line is
	// unioned with the unit's own, so without the reset it could only widen.
	dropinCapabilityKeys = map[string]bool{"AmbientCapabilities": true, "CapabilityBoundingSet": true}
	// The only directives whose grammar admits a trailing "%".
	dropinPercentKeys = map[string]bool{"MemoryMax": true, "CPUQuota": true, "TasksMax": true}
	// ReadWritePaths may name a path strictly beneath one of these. Not
	// /run/powernode: every entry this agent keeps there is its own (identity,
	// storage keys, modules, exec, the overlay and its scratch upper).
	dropinReadWriteRoots = []string{"/persist"}
	// ...and never at or beneath this agent's own state and trust material.
	// MUST mirror System::UnitDropinService::TRUST_PATHS.
	dropinTrustPaths = []string{
		"/persist/var/lib/powernode", "/persist/cache", "/persist/etc", "/persist/lint-discovery",
		"/persist/powernode-traefik", "/persist/dev",
	}
)

const dropinEnvironmentRefusal = "Environment= is not settable through this verb; env tuning needs manifest-declared tunables"

type dropinPair struct{ Key, Value string }

type unitDropinRequest struct {
	Unit       string
	Name       string
	Revert     bool
	Directives []dropinPair
}

func dropinNameRefusal(name string) error {
	if !dropinNameShape.MatchString(name) {
		return taskguard.Refused("name", "must match ^[a-z0-9-]{1,32}$", name)
	}
	return nil
}

func dropinFileName(name string) string { return dropinFilePrefix + name + ".conf" }

// parseUnitDropinOptions validates task.Options: every key, the unit (which
// must exist in the lifecycle unit directory), the name and the directives.
func parseUnitDropinOptions(task *tasks.Task) (unitDropinRequest, error) {
	var req unitDropinRequest
	for key := range task.Options {
		switch key {
		case "unit", "name", "revert", "directives":
		default:
			return req, taskguard.Refused("options."+key, "is not accepted by unit.dropin", "")
		}
	}

	unit, _ := task.Options["unit"].(string)
	if err := validateUnit(unit); err != nil {
		return req, err
	}
	if strings.HasPrefix(strings.ToLower(unit), dropinAgentUnitPrefix) {
		return req, taskguard.Refused("unit", "is the node agent's own unit, which stays out-of-band", unit)
	}
	req.Unit = unit

	name, _ := task.Options["name"].(string)
	if err := dropinNameRefusal(name); err != nil {
		return req, err
	}
	req.Name = name

	if raw, present := task.Options["revert"]; present {
		b, ok := raw.(bool)
		if !ok {
			return req, taskguard.Refused("revert", "must be true or false", fmt.Sprint(raw))
		}
		req.Revert = b
	}

	raw, present := task.Options["directives"]
	if req.Revert {
		if present {
			if list, ok := raw.([]any); !ok || len(list) != 0 {
				return req, taskguard.Refused("directives", "a revert takes no directives", "")
			}
		}
		return req, nil
	}
	if !present {
		return req, taskguard.Refused("directives", "are required unless revert is true", "")
	}
	pairs, err := normalizeDropinDirectives(raw)
	if err != nil {
		return req, err
	}
	resolved, known, err := renderedUnitCapabilities(unit)
	if err != nil {
		return req, err
	}
	if err := dropinCapabilitySubsetRefusal(pairs, resolved, known); err != nil {
		return req, err
	}
	req.Directives = pairs
	return req, nil
}

// renderedUnitCapabilities reads back the capability set this agent rendered
// into the unit's capabilities.conf (security.RenderCapabilityDropInBody:
// CapabilityBoundingSet= reset, then the list). known is false when there is
// no such file — a privileged unit, or one never confined — so the set cannot
// be resolved and only an empty list will pass.
func renderedUnitCapabilities(unit string) (set []string, known bool, err error) {
	path := filepath.Join(security.SystemdDropInRoot(), unit+".d", "capabilities.conf")
	body, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, fmt.Errorf("read %s: %w", path, err)
	}
	for _, line := range strings.Split(string(body), "\n") {
		if v, ok := strings.CutPrefix(strings.TrimSpace(line), "CapabilityBoundingSet="); ok {
			set = strings.Fields(v) // the last assignment wins, as in systemd after a reset
		}
	}
	return set, true, nil
}

// dropinCapabilitySubsetRefusal refuses any non-empty capability list that is
// not a subset of resolved (known false: unresolvable, so nothing but the
// empty list). Mirrors System::UnitDropinService.capability_subset_refusal.
func dropinCapabilitySubsetRefusal(pairs []dropinPair, resolved []string, known bool) error {
	for _, p := range pairs {
		if !dropinCapabilityKeys[p.Key] || p.Value == "" {
			continue
		}
		if !known {
			return taskguard.Refused(p.Key, "this unit has no rendered capability set, so only an empty list (zero capabilities) is accepted", p.Value)
		}
		for _, name := range strings.Split(p.Value, " ") {
			if !slices.Contains(resolved, name) {
				return taskguard.Refused(p.Key, name+" is not in this unit's capability set; a drop-in may only narrow it", p.Value)
			}
		}
	}
	return nil
}

// normalizeDropinDirectives validates a decoded directives list. Mirrors
// System::UnitDropinService.normalize_directives.
func normalizeDropinDirectives(raw any) ([]dropinPair, error) {
	list, ok := raw.([]any)
	if !ok {
		return nil, taskguard.Refused("directives", "must be a list of {key, value} entries", "")
	}
	if len(list) == 0 {
		return nil, taskguard.Refused("directives", "must not be empty", "")
	}
	if len(list) > dropinMaxDirectives {
		return nil, taskguard.Refused("directives", fmt.Sprintf("may hold at most %d entries", dropinMaxDirectives), "")
	}

	seenKeys := map[string]bool{}
	pairs := make([]dropinPair, 0, len(list))
	for i, item := range list {
		field := fmt.Sprintf("directives[%d]", i)
		entry, ok := item.(map[string]any)
		if !ok {
			return nil, taskguard.Refused(field, "must be an object with key and value", "")
		}
		for k := range entry {
			if k != "key" && k != "value" {
				return nil, taskguard.Refused(field+"."+k, "is not accepted (only key and value)", "")
			}
		}
		key, keyOK := entry["key"].(string)
		value, valueOK := entry["value"].(string)
		if !keyOK || !valueOK {
			return nil, taskguard.Refused(field, "key and value must both be strings", "")
		}
		if len(key) > dropinMaxKeyLen || len(value) > dropinMaxValueLen {
			return nil, taskguard.Refused(field, "key or value is too long", "")
		}
		if problem := dropinUnsafeCharacter(key); problem != "" {
			return nil, taskguard.Refused(field+".key", "contains "+problem, "")
		}
		if problem := dropinUnsafeCharacter(value); problem != "" {
			return nil, taskguard.Refused(field+".value", "contains "+problem, "")
		}
		if strings.Contains(value, "%") && !dropinPercentKeys[key] {
			return nil, taskguard.Refused(field+".value", "contains '%': systemd expands %-specifiers in "+key, "")
		}
		if key == "Environment" {
			return nil, taskguard.Refused(field+".key", dropinEnvironmentRefusal, "")
		}
		if !dropinAllowed[key] {
			return nil, taskguard.Refused(field+".key", "is not on the directive allow-list", key)
		}
		if seenKeys[key] {
			return nil, taskguard.Refused(field, key+" is given more than once", "")
		}
		seenKeys[key] = true
		if !dropinValueOK(key, value) {
			return nil, taskguard.Refused(field, key+" value does not match its grammar", value)
		}
		pairs = append(pairs, dropinPair{Key: key, Value: value})
	}
	return pairs, nil
}

// dropinUnsafeCharacter is the rule that keeps one value one line: "" when s
// is safe to place on a directive line.
func dropinUnsafeCharacter(s string) string {
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c < 0x20 || c == 0x7f:
			return "a control character (a line break or NUL would start another directive)"
		case c > 0x7e:
			return "a non-ASCII character"
		case c == '\\':
			return "a backslash (a trailing one continues the line into the next)"
		case c == '[' || c == ']':
			return "a bracket (a section header would start another section)"
		case c == '"':
			return "a double quote"
		}
	}
	return ""
}

func dropinValueOK(key, value string) bool {
	switch {
	case key == "LimitNOFILE":
		return dropinLimitOK(value)
	case dropinCapabilityKeys[key]:
		return dropinCapabilitiesOK(value)
	case key == "ReadWritePaths":
		return dropinPathsOK(value)
	default:
		re, ok := dropinGrammars[key]
		return ok && re.MatchString(value)
	}
}

func dropinLimitOK(value string) bool {
	parts := strings.Split(value, ":")
	if len(parts) < 1 || len(parts) > 2 {
		return false
	}
	for _, p := range parts {
		if !dropinLimitPart.MatchString(p) {
			return false
		}
	}
	if len(parts) == 1 {
		return true
	}
	soft, hard := parts[0], parts[1]
	if soft == "infinity" {
		return hard == "infinity"
	}
	if hard == "infinity" {
		return true
	}
	s, err1 := strconv.ParseUint(soft, 10, 64)
	h, err2 := strconv.ParseUint(hard, 10, 64)
	return err1 == nil && err2 == nil && s <= h
}

func dropinCapabilitiesOK(value string) bool {
	if value == "" {
		return true
	}
	seen := map[string]bool{}
	for _, name := range strings.Split(value, " ") {
		if _, known := security.KnownCapabilities[name]; !known || seen[name] {
			return false
		}
		seen[name] = true
	}
	return true
}

func dropinPathsOK(value string) bool {
	paths := strings.Split(value, " ")
	if value == "" || len(paths) > dropinMaxPaths {
		return false
	}
	for _, p := range paths {
		if !dropinPathShape.MatchString(p) {
			return false
		}
		for _, segment := range strings.Split(p, "/") {
			if segment == "." || segment == ".." {
				return false
			}
		}
		beneath := false
		for _, root := range dropinReadWriteRoots {
			if strings.HasPrefix(p, root+"/") {
				beneath = true
				break
			}
		}
		if !beneath {
			return false
		}
		for _, trust := range dropinTrustPaths {
			if p == trust || strings.HasPrefix(p, trust+"/") {
				return false
			}
		}
	}
	return true
}

// renderDropin is the exact file written. MUST agree byte for byte with
// System::UnitDropinService.render (the shared table pins both).
func renderDropin(name string, pairs []dropinPair) string {
	var b strings.Builder
	b.WriteString("# Managed by Powernode: operator drop-in \"" + name + "\" (system_apply_unit_dropin).\n")
	b.WriteString("# Runtime only: /run is tmpfs, so a reboot removes this file.\n")
	b.WriteString("[Service]\n")
	for _, p := range pairs {
		switch {
		case dropinCapabilityKeys[p.Key]:
			b.WriteString(p.Key + "=\n")
			if p.Value != "" {
				b.WriteString(p.Key + "=" + p.Value + "\n")
			}
		default:
			b.WriteString(p.Key + "=" + p.Value + "\n")
		}
	}
	return b.String()
}

// Execute validates the task, writes or removes the drop-in, then reloads.
// Nothing touches the filesystem or runs a command before every field passes.
func (h *UnitDropinHandler) Execute(ctx context.Context, task *tasks.Task) (tasks.Result, error) {
	req, err := parseUnitDropinOptions(task)
	if err != nil {
		return nil, fmt.Errorf("unit.dropin: %w", err)
	}
	file := dropinFileName(req.Name)
	result := tasks.Result{
		"unit": req.Unit,
		"name": req.Name,
		"path": filepath.Join(dropinCanonicalRoot, req.Unit+".d", file),
	}

	if req.Revert {
		removed, err := removeDropin(dropinRoot, req.Unit, file)
		if err != nil {
			return nil, fmt.Errorf("unit.dropin revert: %w", err)
		}
		result["action"] = "absent"
		if removed {
			result["action"] = "reverted"
		}
	} else {
		replaced, err := writeDropin(dropinRoot, req.Unit, file, []byte(renderDropin(req.Name, req.Directives)))
		if err != nil {
			return nil, fmt.Errorf("unit.dropin write: %w", err)
		}
		result["action"] = "applied"
		result["replaced"] = replaced
	}

	if err := h.deps.MountRunner.Run(ctx, "systemctl", "daemon-reload"); err != nil {
		return nil, fmt.Errorf("systemctl daemon-reload after unit.dropin: %w", err)
	}
	result["restarted"] = false
	return result, nil
}
