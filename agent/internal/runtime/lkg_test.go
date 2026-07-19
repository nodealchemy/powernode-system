package runtime

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// testCachePath returns a digest→erofs-path mapper rooted at dir, mirroring the
// production mount.Layout.ModuleCachePath colon-sanitization.
func testCachePath(dir string) func(string) string {
	return func(digest string) string {
		safe := strings.ReplaceAll(strings.ReplaceAll(digest, ":", "_"), "/", "_")
		return filepath.Join(dir, safe+".erofs")
	}
}

// stageBlob writes a placeholder erofs blob for digest under dir.
func stageBlob(t *testing.T, dir, digest string) {
	t.Helper()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(testCachePath(dir)(digest), []byte("stub-erofs"), 0o644); err != nil {
		t.Fatal(err)
	}
}

// validLKG builds a one-data-module LKG whose blob is staged under cacheDir.
func validLKG(t *testing.T, cacheDir string) *BootLKG {
	t.Helper()
	digest := "sha256:abc123"
	stageBlob(t, cacheDir, digest)
	mfRaw, _ := json.Marshal(map[string]any{"id": "m1", "digest": digest, "effective_priority": 100})
	return &BootLKG{
		ConfirmedAt: time.Now().UTC().Add(-time.Hour),
		Source:      "https://dev.example.test",
		Hostname:    "ops-hub",
		Modules: []LKGModule{
			{ID: "m1", Name: "hub-backend", EffectivePriority: 100, HasDataFile: true, Digest: digest, Manifest: mfRaw},
			{ID: "cfg", Name: "config-only", HasDataFile: false}, // non-data module: no blob, no manifest
		},
	}
}

func TestBootLKG_WriteLoadValidate_RoundTrip(t *testing.T) {
	dir := t.TempDir()
	cacheDir := filepath.Join(dir, "cache")
	path := filepath.Join(dir, "assignment-lkg.json")

	lkg := validLKG(t, cacheDir)
	if err := WriteBootLKG(path, lkg); err != nil {
		t.Fatalf("write: %v", err)
	}
	if !lkg.Frozen {
		t.Fatal("WriteBootLKG must set Frozen=true")
	}

	loaded, err := LoadBootLKG(path)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if err := ValidateBootLKG(loaded, testCachePath(cacheDir)); err != nil {
		t.Fatalf("validate valid LKG: %v", err)
	}

	desired, manifests, err := loaded.ToComposeInputs()
	if err != nil {
		t.Fatalf("ToComposeInputs: %v", err)
	}
	if len(desired) != 1 || desired[0].ID != "m1" || desired[0].Digest != "sha256:abc123" {
		t.Fatalf("desired mismatch: %+v", desired)
	}
	if _, ok := manifests["m1"]; !ok {
		t.Fatal("manifest for m1 missing")
	}
	if _, ok := manifests["cfg"]; ok {
		t.Fatal("non-data module cfg must not produce a mount manifest")
	}
}

func TestBootLKG_ChecksumMismatch_FailLoud(t *testing.T) {
	dir := t.TempDir()
	cacheDir := filepath.Join(dir, "cache")
	path := filepath.Join(dir, "lkg.json")
	lkg := validLKG(t, cacheDir)
	if err := WriteBootLKG(path, lkg); err != nil {
		t.Fatal(err)
	}
	// Corrupt the persisted module set without recomputing the checksum.
	loaded, _ := LoadBootLKG(path)
	loaded.Modules[0].Digest = "sha256:tampered"
	if err := ValidateBootLKG(loaded, testCachePath(cacheDir)); err == nil {
		t.Fatal("expected checksum mismatch error after tampering, got nil")
	}
}

func TestBootLKG_MissingBlob_FailLoud(t *testing.T) {
	dir := t.TempDir()
	cacheDir := filepath.Join(dir, "cache")
	lkg := validLKG(t, cacheDir)
	// Remove the staged blob → validation must fail loud (a fallback compose
	// would otherwise try to mount a blob that isn't there).
	if err := os.Remove(testCachePath(cacheDir)("sha256:abc123")); err != nil {
		t.Fatal(err)
	}
	// Recompute checksum so we're specifically testing the blob check, not the
	// checksum path.
	sum, _ := checksumModules(lkg.Modules)
	lkg.Checksum = sum
	lkg.SchemaVersion = bootLKGSchemaVersion
	if err := ValidateBootLKG(lkg, testCachePath(cacheDir)); err == nil {
		t.Fatal("expected missing-blob error, got nil")
	}
}

func TestBootLKG_SchemaMismatch_FailLoud(t *testing.T) {
	dir := t.TempDir()
	cacheDir := filepath.Join(dir, "cache")
	lkg := validLKG(t, cacheDir)
	sum, _ := checksumModules(lkg.Modules)
	lkg.Checksum = sum
	lkg.SchemaVersion = bootLKGSchemaVersion + 99
	if err := ValidateBootLKG(lkg, testCachePath(cacheDir)); err == nil {
		t.Fatal("expected schema-version error, got nil")
	}
}

func TestBootLKG_EmptyModules_Refused(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "lkg.json")
	if err := WriteBootLKG(path, &BootLKG{Modules: nil}); err == nil {
		t.Fatal("WriteBootLKG must refuse an empty module set")
	}
	if err := ValidateBootLKG(&BootLKG{SchemaVersion: bootLKGSchemaVersion, Modules: nil}, nil); err == nil {
		t.Fatal("ValidateBootLKG must reject an empty module set")
	}
}

func TestBootLKG_OnlyNonDataModules_Rejected(t *testing.T) {
	dir := t.TempDir()
	// A snapshot with only config/skill modules can't compose a root.
	lkg := &BootLKG{
		SchemaVersion: bootLKGSchemaVersion,
		Modules:       []LKGModule{{ID: "cfg", HasDataFile: false}},
	}
	sum, _ := checksumModules(lkg.Modules)
	lkg.Checksum = sum
	if err := ValidateBootLKG(lkg, testCachePath(filepath.Join(dir, "cache"))); err == nil {
		t.Fatal("expected 'no mountable modules' error, got nil")
	}
}

func TestWriteBootLKG_CreatesParentDir(t *testing.T) {
	dir := t.TempDir()
	cacheDir := filepath.Join(dir, "cache")
	// Parent dir does NOT exist — the survival write must self-provision it,
	// not silently no-op (AtomicWriteJSON does not mkdir).
	nested := filepath.Join(dir, "does", "not", "exist", "assignment-lkg.json")
	if err := WriteBootLKG(nested, validLKG(t, cacheDir)); err != nil {
		t.Fatalf("WriteBootLKG must create the parent dir: %v", err)
	}
	if _, err := LoadBootLKG(nested); err != nil {
		t.Fatalf("LKG not written into the fresh dir: %v", err)
	}
}

func TestWriteBreadcrumb_CreatesParentDir(t *testing.T) {
	dir := t.TempDir()
	nested := filepath.Join(dir, "fresh", "boot-composed.json")
	if err := WriteBreadcrumb(nested, &BootComposedBreadcrumb{Modules: []LKGModule{{ID: "m1"}}}); err != nil {
		t.Fatalf("WriteBreadcrumb must create the parent dir: %v", err)
	}
	if _, err := LoadBreadcrumb(nested); err != nil {
		t.Fatalf("breadcrumb not written into the fresh dir: %v", err)
	}
}

// HIGH-1: arm-telemetry is emitted on EVERY boot's heartbeat (not just fallback
// boots), read from the on-disk frozen LKG, so an operator can verify a node is
// armed before #14 pulls its control plane.
func TestBuildHeartbeat_ArmTelemetry_OnNormalBoot(t *testing.T) {
	dir := t.TempDir()
	cacheDir := filepath.Join(dir, "cache")
	origLKG, origBC := BootLKGPath, BootBreadcrumbPath
	BootLKGPath = filepath.Join(dir, "assignment-lkg.json")
	BootBreadcrumbPath = filepath.Join(dir, "boot-composed.json")
	defer func() { BootLKGPath, BootBreadcrumbPath = origLKG, origBC }()

	if err := WriteBootLKG(BootLKGPath, validLKG(t, cacheDir)); err != nil {
		t.Fatal(err)
	}
	// A normal (non-fallback) boot breadcrumb.
	if err := WriteBreadcrumb(BootBreadcrumbPath, &BootComposedBreadcrumb{Modules: []LKGModule{{ID: "m1"}}}); err != nil {
		t.Fatal(err)
	}
	s := &Service{cfg: Config{StatePath: filepath.Join(dir, "state.json"), OnError: func(string, error) {}}}
	p := s.buildHeartbeat("boot-1", nil)
	if !p.LKGPresent {
		t.Fatal("arm-telemetry: lkg_present must be true when a frozen LKG is on disk")
	}
	// validLKG has 2 modules (1 data + 1 config); the count reflects the full set.
	if p.LKGModuleCount != 2 {
		t.Fatalf("lkg_module_count: got %d want 2", p.LKGModuleCount)
	}
	if p.LKGConfirmedAt == "" {
		t.Fatal("lkg_confirmed_at must be emitted")
	}
	if p.BootedFromLKG {
		t.Fatal("a normal boot must not report booted_from_lkg")
	}
	if p.BootIncomplete {
		t.Fatal("a complete boot must not report boot_incomplete")
	}
}

func TestLKGFallbackDisabled_Sentinel(t *testing.T) {
	dir := t.TempDir()
	sentinel := filepath.Join(dir, "lkg-fallback.disabled")
	// Point the cmdline read at a file with no lkg flag so only the sentinel matters.
	restore := procCmdlinePath
	procCmdlinePath = filepath.Join(dir, "cmdline")
	_ = os.WriteFile(procCmdlinePath, []byte("BOOT_IMAGE=/x ro quiet\n"), 0o644)
	defer func() { procCmdlinePath = restore }()

	if LKGFallbackDisabled(sentinel) {
		t.Fatal("no sentinel + no cmdline flag → fallback must be ENABLED (default)")
	}
	if err := os.WriteFile(sentinel, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	if !LKGFallbackDisabled(sentinel) {
		t.Fatal("sentinel present → fallback must be DISABLED")
	}
}

func TestLKGFallbackDisabled_KernelCmdline(t *testing.T) {
	dir := t.TempDir()
	restore := procCmdlinePath
	procCmdlinePath = filepath.Join(dir, "cmdline")
	defer func() { procCmdlinePath = restore }()

	_ = os.WriteFile(procCmdlinePath, []byte("BOOT_IMAGE=/x ro powernode.lkg=off quiet\n"), 0o644)
	if !LKGFallbackDisabled("") {
		t.Fatal("powernode.lkg=off on cmdline → fallback must be DISABLED")
	}
	_ = os.WriteFile(procCmdlinePath, []byte("BOOT_IMAGE=/x ro quiet\n"), 0o644)
	if LKGFallbackDisabled("") {
		t.Fatal("no powernode.lkg flag → fallback must be ENABLED (default)")
	}
}

func TestStalenessThreshold_Precedence(t *testing.T) {
	dir := t.TempDir()
	restore := procCmdlinePath
	procCmdlinePath = filepath.Join(dir, "cmdline")
	defer func() { procCmdlinePath = restore }()

	// No cmdline override, no recorded → compile-time default.
	_ = os.WriteFile(procCmdlinePath, []byte("ro quiet\n"), 0o644)
	if got := stalenessThreshold(0); got != DefaultLKGStalenessThreshold {
		t.Fatalf("default: got %s want %s", got, DefaultLKGStalenessThreshold)
	}
	// Recorded (backend-delivered) beats the default.
	if got := stalenessThreshold(3600); got != time.Hour {
		t.Fatalf("recorded: got %s want 1h", got)
	}
	// Kernel cmdline beats the recorded value.
	_ = os.WriteFile(procCmdlinePath, []byte("ro powernode.lkg_max_age=60 quiet\n"), 0o644)
	if got := stalenessThreshold(3600); got != time.Minute {
		t.Fatalf("cmdline override: got %s want 1m", got)
	}
}
