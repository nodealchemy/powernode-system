package runtime

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/signingaudit"
)

// IMP-c52b5c2d6cbf — the audit rungs exist to MEASURE what enforcing would
// refuse. Until this block, every finding went to the node's stderr and
// nowhere else, so "run audit until the fleet is quiet" meant reading every
// node's journal by hand. The heartbeat is the channel the fleet already has.
func TestHeartbeatCarriesSigningAuditFindings(t *testing.T) {
	c := signingaudit.New(signingaudit.DefaultMaxFindings)
	c.Report("verify:module_signature_audit", errors.New("would refuse /persist/blobs/aa: no cosign bundle"))

	wire := marshalHeartbeat(t, c)
	block, ok := wire["module_signing_audit"].(map[string]any)
	if !ok {
		t.Fatalf("module_signing_audit must ride the heartbeat, got %v", wire["module_signing_audit"])
	}
	findings, ok := block["findings"].([]any)
	if !ok || len(findings) != 1 {
		t.Fatalf("the findings must ride the block, got %v", block["findings"])
	}
	entry := findings[0].(map[string]any)
	if entry["stage"] != "verify:module_signature_audit" {
		t.Errorf("stage lost on the wire: %v", entry["stage"])
	}
	if entry["count"].(float64) != 1 {
		t.Errorf("count lost on the wire: %v", entry["count"])
	}
}

// THE BLOCKING PROPERTY. Enforcing is justified by the ABSENCE of findings, so
// an active-and-quiet node must reach the platform as a present, empty
// measurement. `omitempty` erases an empty slice as readily as a nil one, which
// is why the block is a pointer to a struct: the distinction has to survive
// encoding, or a quiet fleet is byte-identical to a fleet that never measured.
func TestHeartbeatCarriesAnEmptyMeasurementFromAQuietNode(t *testing.T) {
	c := signingaudit.New(signingaudit.DefaultMaxFindings)
	c.MarkActive("audit")

	wire := marshalHeartbeat(t, c)
	block, ok := wire["module_signing_audit"].(map[string]any)
	if !ok {
		t.Fatalf("a quiet node that MEASURED must still send the block, got %v", wire["module_signing_audit"])
	}
	findings, ok := block["findings"].([]any)
	if !ok || len(findings) != 0 {
		t.Fatalf("a quiet node sends an empty findings list, got %v", block["findings"])
	}
	// An empty list means different things on different rungs, so the rung has
	// to travel with it — see signingaudit.Observation.
	if block["mode"] != "audit" {
		t.Errorf("the rung must ride the wire with the measurement, got %v", block["mode"])
	}
}

// Absence must stay absence: a node running signing `off` (or an agent older
// than this block) omits the key, so the platform records NOT MEASURED rather
// than an empty block a reader could mistake for "clean".
func TestHeartbeatOmitsSigningAuditWhenAuditNeverRan(t *testing.T) {
	wire := marshalHeartbeat(t, signingaudit.New(signingaudit.DefaultMaxFindings))
	if _, present := wire["module_signing_audit"]; present {
		t.Fatalf("an unmeasured node must omit the key entirely, got %v", wire["module_signing_audit"])
	}
}

// A dropped finding must be visible to the reader, or finding_count reads as
// "this node's problems" when it is only the size of the collector's window.
func TestHeartbeatCarriesTheTruncationFlag(t *testing.T) {
	c := signingaudit.New(1)
	c.Report("verify:module_signature_audit", errors.New("would refuse /b/one: x"))
	c.Report("verify:module_signature_audit", errors.New("would refuse /b/two: x"))

	block := marshalHeartbeat(t, c)["module_signing_audit"].(map[string]any)
	if block["truncated"] != true {
		t.Fatalf("truncation must ride the wire, got %v", block["truncated"])
	}
}

func marshalHeartbeat(t *testing.T, c *signingaudit.Collector) map[string]any {
	t.Helper()
	p := HeartbeatPayload{BootID: "b", AgentVersion: "v"}
	p.ModuleSigningAudit = c.Snapshot()

	raw, err := json.Marshal(p)
	if err != nil {
		t.Fatal(err)
	}
	var wire map[string]any
	if err := json.Unmarshal(raw, &wire); err != nil {
		t.Fatal(err)
	}
	return wire
}

// The payload wiring itself: buildHeartbeat must read the collector the service
// tees its module-signing reports into. Without this, deleting the snapshot
// line would leave every other test green while findings stopped leaving the
// node — the exact failure this task exists to fix.
func TestBuildHeartbeatEmbedsSigningAuditFindings(t *testing.T) {
	s := newAuditTestService(t)
	s.signingAudit.Report("verify:module_fsverity_audit",
		errors.New("would refuse /persist/blobs/bb: fsverity: executable file not found"))

	payload := s.buildHeartbeat("boot-1", nil)

	if payload.ModuleSigningAudit == nil || len(payload.ModuleSigningAudit.Findings) != 1 {
		t.Fatalf("the heartbeat must carry the collected findings, got %+v", payload.ModuleSigningAudit)
	}
	if payload.ModuleSigningAudit.Findings[0].Stage != "verify:module_fsverity_audit" {
		t.Errorf("stage lost: %+v", payload.ModuleSigningAudit.Findings[0])
	}
}

// A service whose audit never ran omits the block, so the platform records NOT
// MEASURED rather than a clean-looking empty one.
func TestBuildHeartbeatOmitsSigningAuditWhenAuditNeverRan(t *testing.T) {
	if got := newAuditTestService(t).buildHeartbeat("boot-1", nil).ModuleSigningAudit; got != nil {
		t.Fatalf("an unmeasured audit must stay nil, got %+v", got)
	}
}

// Built through New(), not a Service literal: New is what wires the collector
// in production, so a constructor that stopped doing so must fail here.
func newAuditTestService(t *testing.T) *Service {
	t.Helper()
	return New(Config{
		AgentVersion: "test",
		StatePath:    filepath.Join(t.TempDir(), "state.json"),
		OnError:      func(string, error) {},
	})
}

// TEE, NOT REPLACEMENT — pinned at the CALL SITES, not just on the helper.
// signingaudit.Tee is unit-tested to preserve its inner hook, but that proves
// nothing about what Run() passes: swapping either resolver's argument for
// `s.signingAudit.Report` leaves every other test in this change green while
// the node's journal silently loses every audit line, trading a local signal
// for a remote one. Like TestModuleMountVerifierWiringIsConfigDriven this is a
// source-shape guard because the property is package-level WIRING inside Run(),
// not behaviour observable from a constructed Service.
func TestSigningAuditIsTeedOntoTheExistingErrorHookAtEveryResolverCall(t *testing.T) {
	b, err := os.ReadFile("service.go")
	if err != nil {
		t.Fatalf("read service.go: %v", err)
	}
	src := string(b)

	for _, resolver := range []string{"ResolveModuleVerifier", "ResolveModuleFsverity"} {
		// Span the whole STATEMENT, up to its `if err != nil` guard, rather
		// than stopping at the first `)`. Stopping at the first paren happens
		// to work only while no earlier argument contains one; the moment a
		// call like newClient(x) is passed before the hook, a first-paren
		// regex truncates the capture and fails a legal refactor with a
		// misleading message.
		re := regexp.MustCompile(`(?s)` + regexp.QuoteMeta(resolver) + `\(.*?\n\tif err != nil`)
		call := re.FindString(src)
		if call == "" {
			t.Fatalf("service.go no longer calls %s — the signing-audit collector's "+
				"report hook is wired through it", resolver)
		}
		if !regexp.MustCompile(`signingAudit\.Tee\(`).MatchString(call) {
			t.Errorf("service.go's %s call must pass s.signingAudit.Tee(s.cfg.OnError), "+
				"not the collector's Report alone: the stderr hook is the live-debugging "+
				"signal and must keep receiving every report. Got: %s", resolver, call)
		}
		if !regexp.MustCompile(`Tee\(s\.cfg\.OnError\)`).MatchString(call) {
			t.Errorf("service.go's %s call tees onto something other than s.cfg.OnError; "+
				"the journal would stop seeing audit findings. Got: %s", resolver, call)
		}
	}
}

// The collector is only marked ACTIVE when the operator's policy actually runs
// a verification pass. Without this, `signing off` and `audit on + clean` both
// produce an empty measurement and the platform would record a node that
// verifies NOTHING as QUIET — inverted evidence at the moment an operator
// decides to enforce.
// Asserted as ONE RELATIONSHIP, not as two independent greps. Two separate
// "the file mentions Active()" / "the file mentions MarkActive()" checks stay
// green when the guard is INVERTED to `if !s.cfg.ModuleSigning.Active()`, which
// is the worst reachable state: an `off` node reports QUIET and an audited node
// reports NOT MEASURED — precisely the confusion this whole block exists to
// remove, with the sign flipped.
func TestRunMarksTheSigningAuditActiveOnlyWhenPolicyIsActive(t *testing.T) {
	b, err := os.ReadFile("service.go")
	if err != nil {
		t.Fatalf("read service.go: %v", err)
	}
	src := string(b)
	guard := regexp.MustCompile(`if\s+s\.cfg\.ModuleSigning\.Active\(\)\s*\{\s*\n\s*s\.signingAudit\.MarkActive\(`)
	if !guard.MatchString(src) {
		t.Error("service.go must mark the signing-audit collector active INSIDE an " +
			"`if s.cfg.ModuleSigning.Active()` guard: unguarded, an `off` node reports " +
			"itself QUIET; unmarked, a clean audited node never reports its measurement")
	}
	if regexp.MustCompile(`if\s+!\s*s\.cfg\.ModuleSigning\.Active\(\)`).MatchString(src) {
		t.Error("service.go negates the module-signing active check; inverted, `off` nodes " +
			"report QUIET and audited nodes report NOT MEASURED")
	}
	// The rung travels with the measurement — an empty list means different
	// things under audit and under runtime/all.
	if !regexp.MustCompile(`MarkActive\(s\.cfg\.ModuleSigning\.Mode\)`).MatchString(src) {
		t.Error("service.go must pass the configured mode to MarkActive, or the platform " +
			"cannot tell which arms were reporting into an empty measurement")
	}
}
