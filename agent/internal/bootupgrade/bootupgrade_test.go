package bootupgrade

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/bootslots"
	"github.com/nodealchemy/powernode-system/agent/internal/espwrite"
)

// fakeRunner fails on cosign and records whether the ESP was ever touched, so a
// test can prove an unverified UKI never reaches the ESP write.
type fakeRunner struct {
	cosignErr error
	sawBlkid  bool
	sawMount  bool
}

func (f *fakeRunner) Run(_ context.Context, name string, _ ...string) error {
	if name == "cosign" {
		return f.cosignErr
	}
	if name == "mount" {
		f.sawMount = true
	}
	return nil
}

func (f *fakeRunner) Output(_ context.Context, name string, _ ...string) ([]byte, error) {
	if name == "blkid" || name == "lsblk" {
		f.sawBlkid = true
	}
	return nil, errors.New("no device")
}

func TestApply_ValidateRejectsMissingFields(t *testing.T) {
	if _, err := Apply(context.Background(), Deps{}, Options{}); err == nil {
		t.Fatal("expected a validation error for empty options")
	}
	// A payload missing only the cosign bundle must still be rejected — we never
	// dispatch an unverifiable image.
	_, err := Apply(context.Background(), Deps{}, Options{
		TargetGitSHA: "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef", UkiSha256: "b", DownloadPath: "/d",
		CosignPublicKey: "key",
	})
	if err == nil || !strings.Contains(err.Error(), "cosign_bundle_b64") {
		t.Fatalf("want cosign_bundle_b64 required, got %v", err)
	}
	// And missing the public key must be rejected.
	_, err = Apply(context.Background(), Deps{}, Options{
		TargetGitSHA: "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef", UkiSha256: "b", DownloadPath: "/d",
		CosignBundleB64: "eA==",
	})
	if err == nil || !strings.Contains(err.Error(), "cosign_public_key") {
		t.Fatalf("want cosign_public_key required, got %v", err)
	}
}

func TestApply_CosignFailureRefusesESPWrite(t *testing.T) {
	stage := t.TempDir()
	payload := []byte("candidate-uki-bytes")
	sum := sha256.Sum256(payload)
	sha := hex.EncodeToString(sum[:])
	// Pre-stage the UKI so the download is skipped and no client is needed.
	if err := os.WriteFile(filepath.Join(stage, sha+".uki"), payload, 0o600); err != nil {
		t.Fatal(err)
	}

	fr := &fakeRunner{cosignErr: errors.New("certificate identity mismatch")}
	_, err := Apply(context.Background(), Deps{Runner: fr, StageDir: stage}, Options{
		TargetGitSHA:    "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
		UkiSha256:       sha,
		CosignPublicKey: "-----BEGIN PUBLIC KEY-----\ntest\n-----END PUBLIC KEY-----",
		CosignBundleB64: base64.StdEncoding.EncodeToString([]byte("bundle")),
		DownloadPath:    "/download",
	})

	if err == nil || !strings.Contains(err.Error(), "cosign verify") {
		t.Fatalf("want a cosign verify error, got %v", err)
	}
	// SECURITY: the unverified UKI must be removed and the ESP never touched.
	if _, statErr := os.Stat(filepath.Join(stage, sha+".uki")); !os.IsNotExist(statErr) {
		t.Error("an unverified UKI must be removed from staging")
	}
	if fr.sawBlkid || fr.sawMount {
		t.Error("the ESP must not be located/mounted when cosign verification fails")
	}
}

func TestApply_SkipsDownloadForCachedVerifiedBytes(t *testing.T) {
	// With a nil client, Apply must not attempt a download when the staged file
	// already matches the target digest — it should proceed to (failing) cosign.
	stage := t.TempDir()
	payload := []byte("already-cached")
	sum := sha256.Sum256(payload)
	sha := hex.EncodeToString(sum[:])
	if err := os.WriteFile(filepath.Join(stage, sha+".uki"), payload, 0o600); err != nil {
		t.Fatal(err)
	}
	fr := &fakeRunner{cosignErr: errors.New("stop here")}
	_, err := Apply(context.Background(), Deps{Runner: fr, StageDir: stage}, Options{
		TargetGitSHA: "abcdefabcdefabcdefabcdefabcdefabcdefabcd", UkiSha256: sha, DownloadPath: "/d",
		CosignPublicKey: "-----BEGIN PUBLIC KEY-----\ntest\n-----END PUBLIC KEY-----",
		CosignBundleB64: base64.StdEncoding.EncodeToString([]byte("b")),
	})
	// It reached cosign (not a "nil transport client" download error).
	if err == nil || !strings.Contains(err.Error(), "cosign verify") {
		t.Fatalf("cached bytes should skip download and reach cosign; got %v", err)
	}
}

// stageVerifiedUKI writes a UKI whose sha matches its name so Apply skips the
// download, and returns that sha.
func stageVerifiedUKI(t *testing.T, stage string) string {
	t.Helper()
	body := []byte("fake-uki-bytes")
	sum := sha256.Sum256(body)
	sha := hex.EncodeToString(sum[:])
	if err := os.WriteFile(filepath.Join(stage, sha+".uki"), body, 0o600); err != nil {
		t.Fatal(err)
	}
	return sha
}

func applyOpts(sha string) Options {
	return Options{
		TargetGitSHA:    "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
		UkiSha256:       sha,
		DownloadPath:    "/api/v1/system/node_api/boot_image/download",
		CosignBundleB64: base64.StdEncoding.EncodeToString([]byte("bundle")),
		CosignPublicKey: "-----BEGIN PUBLIC KEY-----\nx\n-----END PUBLIC KEY-----\n",
	}
}

// TestApply_RefusesWhenNotBootedViaSystemdBoot covers the behavioural change made
// on 2026-07-25. The old code fell through here to a single-slot writer that
// replaced /EFI/BOOT/<removable> — systemd-boot itself — with the payload, which
// bricked VM 9002 unrecoverably. Apply must now refuse, and must not touch the
// ESP at all. Without this test a regression re-adding the fallback passes every
// other test in the repo.
func TestApply_RefusesWhenNotBootedViaSystemdBoot(t *testing.T) {
	restore := bootslots.SetEfivarsDirForTest(t.TempDir()) // empty → no LoaderInfo
	defer restore()

	stage := t.TempDir()
	sha := stageVerifiedUKI(t, stage)
	fr := &fakeRunner{} // cosign succeeds, so we reach the A/B precondition

	slot, err := Apply(context.Background(), Deps{Runner: fr, StageDir: stage}, applyOpts(sha))
	if err == nil {
		t.Fatal("expected Apply to refuse on a node with no A/B layout, got nil error")
	}
	if !strings.Contains(err.Error(), "refusing boot-image upgrade") {
		t.Fatalf("error should explain the refusal, got: %v", err)
	}
	if slot != "" {
		t.Errorf("refusal must not report a written slot, got %q", slot)
	}
	if fr.sawMount {
		t.Error("refusal must not mount or write the ESP")
	}
}

// TestApply_ProceedsPastPreconditionWhenLoaderInfoPresent is the negative control
// for the test above: with LoaderInfo present the refusal must NOT be the failure
// reason, proving the guard keys off the real variable rather than always
// refusing.
func TestApply_ProceedsPastPreconditionWhenLoaderInfoPresent(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(
		filepath.Join(dir, "LoaderInfo-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f"),
		[]byte("systemd-boot 255.4"), 0o644); err != nil {
		t.Fatal(err)
	}
	restore := bootslots.SetEfivarsDirForTest(dir)
	defer restore()

	stage := t.TempDir()
	sha := stageVerifiedUKI(t, stage)
	fr := &fakeRunner{}

	// Fails later (no real ESP in a temp dir) — the point is only that it is no
	// longer the no-A/B-layout refusal.
	_, err := Apply(context.Background(), Deps{Runner: fr, StageDir: stage}, applyOpts(sha))
	if err != nil && strings.Contains(err.Error(), "did not boot via systemd-boot") {
		t.Fatalf("must not refuse when LoaderInfo is present, got: %v", err)
	}
}

// --- ConfirmBoot -------------------------------------------------------------
//
// These cover the branch that deleted a running node's boot file. The rule they
// enforce: ConfirmBoot may only remove a slot's files when it is CERTAIN the slot
// did not boot. Anything less than certain must leave the ESP alone.

// espSpy records EVERY command attempted. Recording only "mount" is not enough:
// ESP work begins with a blkid/lsblk probe via Output, and a test that watches
// only mount can pass because the code failed earlier for an unrelated reason.
type espSpy struct{ cmds []string }

func (e *espSpy) Run(_ context.Context, name string, _ ...string) error {
	e.cmds = append(e.cmds, name)
	return nil
}
func (e *espSpy) Output(_ context.Context, name string, _ ...string) ([]byte, error) {
	e.cmds = append(e.cmds, name)
	return nil, errors.New("no device")
}
func (e *espSpy) touchedESP() bool { return len(e.cmds) > 0 }

// confirmEnv points bootslots at a temp state file and a temp efivars dir
// containing a real LoaderInfo, i.e. "booted via systemd-boot".
func confirmEnv(t *testing.T, st bootslots.State) *espSpy {
	return confirmEnvWithEntry(t, st, "")
}

// utf16leVar renders an EFI variable body: 4-byte attribute prefix + UTF-16LE.
func utf16leVar(sv string) []byte {
	b := []byte{7, 0, 0, 0}
	for _, r := range sv {
		b = append(b, byte(r), byte(r>>8))
	}
	return append(b, 0, 0) // sd-boot NUL-terminates; exercises the TrimRight
}

// confirmEnvWithEntry additionally publishes LoaderEntrySelected, i.e. tells the
// agent which slot systemd-boot really booted. entry "" omits it.
func confirmEnvWithEntry(t *testing.T, st bootslots.State, entry string) *espSpy {
	t.Helper()
	ev := t.TempDir()
	if entry != "" {
		if err := os.WriteFile(
			filepath.Join(ev, "LoaderEntrySelected-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f"),
			utf16leVar(entry), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(
		filepath.Join(ev, "LoaderInfo-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f"),
		[]byte("systemd-boot 255.4"), 0o644); err != nil {
		t.Fatal(err)
	}
	restoreEv := bootslots.SetEfivarsDirForTest(ev)
	t.Cleanup(restoreEv)

	// Force the UEFI marker true, otherwise ESP helpers short-circuit in IsUEFI
	// and "we never touched the ESP" would pass for the wrong reason on a BIOS host.
	restoreEfi := espwrite.SetEFIDirForTest(t.TempDir())
	t.Cleanup(restoreEfi)

	sp := filepath.Join(t.TempDir(), "boot-slot.json")
	restoreSp := bootslots.SetStatePathForTest(sp)
	t.Cleanup(restoreSp)

	if err := st.SaveTo(sp); err != nil {
		t.Fatal(err)
	}
	return &espSpy{}
}

func TestConfirmBoot_NoPendingIsNoOp(t *testing.T) {
	spy := confirmEnv(t, bootslots.State{Active: "a"})
	if err := ConfirmBoot(context.Background(), spy, "abc"); err != nil {
		t.Fatalf("no pending upgrade should be a clean no-op, got %v", err)
	}
	if spy.touchedESP() {
		t.Errorf("no-op must not touch the ESP, ran: %v", spy.cmds)
	}
}

// The regression guard for the 2026-07-25 defect class: an unknown booted sha is
// NOT evidence of rollback. Erroring keeps Pending set; cleaning would delete the
// boot file of the slot we may well be running from.
func TestConfirmBoot_EmptyShaErrorsAndPreservesPendingAndESP(t *testing.T) {
	spy := confirmEnv(t, bootslots.State{Active: "a", Pending: "b", PendingSHA: "deadbeef"})

	err := ConfirmBoot(context.Background(), spy, "")
	if err == nil {
		t.Fatal("empty booted sha must error, not be treated as rollback")
	}
	if spy.touchedESP() {
		t.Errorf("must not touch the ESP when the booted sha is unknown, ran: %v", spy.cmds)
	}
	if st := bootslots.Load(); st.Pending != "b" || st.PendingSHA != "deadbeef" {
		t.Fatalf("Pending must survive so a later boot can resolve it, got %+v", st)
	}
}

// A mismatched (non-empty) sha is the far more likely rollback, but still not
// provable — so Pending clears while the ESP is left untouched. Cleaning here is
// what would delete a running-but-unblessed slot's only boot file.
func TestConfirmBoot_MismatchClearsPendingWithoutTouchingESP(t *testing.T) {
	spy := confirmEnv(t, bootslots.State{Active: "a", Pending: "b", PendingSHA: "target-sha"})

	if err := ConfirmBoot(context.Background(), spy, "some-other-sha"); err != nil {
		t.Fatalf("a mismatch is an ordinary rollback, not an error: %v", err)
	}
	if spy.touchedESP() {
		t.Errorf("mismatch must NOT clean the slot — it may be the slot we are running from; ran: %v", spy.cmds)
	}
	st := bootslots.Load()
	if st.Pending != "" || st.PendingSHA != "" {
		t.Errorf("Pending must clear after a mismatch, got %+v", st)
	}
	if st.Active != "a" {
		t.Errorf("Active must not advance on a mismatch, got %q", st.Active)
	}
}

// With a slot pending but the boot method undeterminable, ConfirmBoot must NOT
// report success — the caller latches "blessed" on nil and would never retry,
// silently abandoning a healthy upgrade.
func TestConfirmBoot_PendingButNotSystemdBootErrors(t *testing.T) {
	sp := filepath.Join(t.TempDir(), "boot-slot.json")
	restoreSp := bootslots.SetStatePathForTest(sp)
	defer restoreSp()
	if err := (bootslots.State{Active: "a", Pending: "b", PendingSHA: "x"}).SaveTo(sp); err != nil {
		t.Fatal(err)
	}
	restoreEv := bootslots.SetEfivarsDirForTest(t.TempDir()) // empty: no LoaderInfo
	defer restoreEv()

	spy := &espSpy{}
	if err := ConfirmBoot(context.Background(), spy, "x"); err == nil {
		t.Fatal("a pending slot with an undeterminable boot method must error, not report success")
	}
	if st := bootslots.Load(); st.Pending != "b" {
		t.Errorf("Pending must survive, got %+v", st)
	}
}

// Regression guard: a node with no upgrade in flight must not be written to at
// all. An unconditional save here turned a clean no-op into a per-tick permanent
// error on every node whose /persist is not writable — fleet-wide, including
// nodes that have never upgraded.
func TestConfirmBoot_NoPendingMustNotCreateStateFile(t *testing.T) {
	sp := filepath.Join(t.TempDir(), "boot-slot.json") // deliberately absent
	defer bootslots.SetStatePathForTest(sp)()
	ev := t.TempDir()
	if err := os.WriteFile(
		filepath.Join(ev, "LoaderInfo-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f"),
		[]byte("systemd-boot 255.4"), 0o644); err != nil {
		t.Fatal(err)
	}
	defer bootslots.SetEfivarsDirForTest(ev)()

	spy := &espSpy{}
	if err := ConfirmBoot(context.Background(), spy, "somesha"); err != nil {
		t.Fatalf("no pending upgrade must be a clean no-op, got %v", err)
	}
	if _, err := os.Stat(sp); err == nil {
		b, _ := os.ReadFile(sp)
		t.Fatalf("must not create the state file when nothing is pending; wrote %s", b)
	}
	if spy.touchedESP() {
		t.Errorf("must not touch the ESP, ran: %v", spy.cmds)
	}
}

// Authoritative rollback: systemd-boot reports we are on the OTHER slot. That is
// the routine, designed outcome — clear the attempt and report success, so it
// does not error every tick for the rest of the boot.
func TestConfirmBoot_AuthoritativeRollbackClearsCleanly(t *testing.T) {
	spy := confirmEnvWithEntry(t,
		bootslots.State{Active: "a", Pending: "b", PendingSHA: "aaaa"}, "powernode-a.efi")

	if err := ConfirmBoot(context.Background(), spy, "old-image-sha"); err != nil {
		t.Fatalf("a detected rollback is routine, not an error: %v", err)
	}
	if spy.touchedESP() {
		t.Errorf("rollback must not touch the ESP, ran: %v", spy.cmds)
	}
	if st := bootslots.Load(); st.Pending != "" || st.Active != "a" {
		t.Errorf("rollback must clear Pending and leave Active, got %+v", st)
	}
}

// The dangerous case the sha comparison alone could not see: we ARE running the
// pending slot, but it reports a different sha than requested (wrong target).
// Cleaning here would delete the running slot's only boot file — it is unblessed,
// so no counterless copy exists.
func TestConfirmBoot_OnPendingSlotWithWrongShaRefusesAndRetains(t *testing.T) {
	spy := confirmEnvWithEntry(t,
		bootslots.State{Active: "a", Pending: "b", PendingSHA: "requested-sha"}, "powernode-b+2-1.efi")

	err := ConfirmBoot(context.Background(), spy, "what-actually-booted")
	if err == nil {
		t.Fatal("running the pending slot with a mismatched sha is unprovable — must not report success")
	}
	if spy.touchedESP() {
		t.Errorf("must not touch the ESP for the slot we are running from, ran: %v", spy.cmds)
	}
	if st := bootslots.Load(); st.Pending != "b" {
		t.Errorf("Pending must be retained for the next boot, got %+v", st)
	}
}

// The case the authoritative signal exists for: a node that genuinely rolled back
// to an image carrying NO git_sha marker. LoaderEntrySelected proves the rollback,
// so this must clear cleanly. Checking the sha first would error here on every
// heartbeat tick for the rest of the boot, since the sha cannot change within a
// boot — the same permanent-per-tick failure the mismatch path refuses to inflict.
func TestConfirmBoot_RollbackToUnmarkedImageClearsCleanly(t *testing.T) {
	spy := confirmEnvWithEntry(t,
		bootslots.State{Active: "a", Pending: "b", PendingSHA: "requested-sha"}, "powernode-a.efi")

	if err := ConfirmBoot(context.Background(), spy, ""); err != nil {
		t.Fatalf("rollback is provable from LoaderEntrySelected even with no sha marker: %v", err)
	}
	if spy.touchedESP() {
		t.Errorf("rollback must not touch the ESP, ran: %v", spy.cmds)
	}
	if st := bootslots.Load(); st.Pending != "" {
		t.Errorf("a proven rollback must clear Pending, got %+v", st)
	}
}

// Guard for the loose-prefix bug: only our own slot entries may match.
func TestBootedSlotIgnoresForeignPowernodeEntries(t *testing.T) {
	for _, c := range []struct{ entry, want string }{
		{"powernode-a.efi", "a"},
		{"powernode-b+2-1.efi", "b"},
		{"powernode-backup.efi", ""}, // must NOT read as slot b
		{"powernode-alt.efi", ""},    // must NOT read as slot a
		{"ubuntu.efi", ""},
	} {
		ev := t.TempDir()
		if err := os.WriteFile(
			filepath.Join(ev, "LoaderEntrySelected-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f"),
			utf16leVar(c.entry), 0o644); err != nil {
			t.Fatal(err)
		}
		restore := bootslots.SetEfivarsDirForTest(ev)
		if got := bootslots.BootedSlot(); got != c.want {
			t.Errorf("BootedSlot(%q) = %q, want %q", c.entry, got, c.want)
		}
		restore()
	}
}

// Risk 3 from the INV-8 review: a second upgrade dispatched while a slot is
// still pending confirmation would clear the slot family of the image the node
// is CURRENTLY running from (unblessed ⇒ its counter-suffixed file is its only
// boot file), replacing a running image with an unproven one.
func TestApply_RefusesWhileAnUpgradeIsPendingConfirmation(t *testing.T) {
	dir := t.TempDir()
	restoreState := bootslots.SetStatePathForTest(filepath.Join(dir, "boot-slot.json"))
	defer restoreState()
	restoreEFI := espwrite.SetEFIDirForTest(dir)
	defer restoreEFI()

	if err := bootslots.Update(func(st *bootslots.State) error {
		st.Active = "a"
		st.Pending = "b"
		st.PendingSHA = "deadbeef"
		return nil
	}); err != nil {
		t.Fatal(err)
	}

	spy := &espSpy{}
	_, err := Apply(context.Background(), Deps{Runner: spy}, Options{
		TargetGitSHA:    "1111111111111111111111111111111111111111",
		UkiSha256:       "2222222222222222222222222222222222222222222222222222222222222222",
		CosignPublicKey: "k",
		CosignBundleB64: "Yg==",
		DownloadPath:    "/dl",
	})
	if err == nil {
		t.Fatal("expected refusal while a slot is pending confirmation")
	}
	if !strings.Contains(err.Error(), "pending confirmation") {
		t.Errorf("wrong refusal reason: %v", err)
	}
	// The ESP must be untouched — no mount, no write, nothing.
	if spy.touchedESP() {
		t.Errorf("ESP was touched despite refusal: ran %v", spy.cmds)
	}
}

// NOTE — the Apply ordering fix (record Pending BEFORE arming the one-shot) has
// NO unit coverage, deliberately rather than by oversight.
//
// A test was written and then removed: it passed with the bug reintroduced. In
// this harness Apply never reaches `bootctl set-oneshot` at all — WriteUKISlot
// goes through espwrite.withMountedESP, which needs a real UEFI node and a
// mounted ESP, so the run dies before the ordering under test is exercised. A
// test that cannot be demonstrated failing is not evidence, and shipping one
// here would assert coverage that does not exist.
//
// Real coverage needs an injection seam in withMountedESP — the same missing
// seam that leaves Apply's rollback-target refusal (INV-8 residual risk 5)
// covered only at the predicate level. Tracked with that work; until then the
// ordering is guaranteed structurally instead: Apply is now the single writer of
// the pending record, and it fails closed if the record cannot be written, so
// the arm cannot be reached with the state unwritten.
