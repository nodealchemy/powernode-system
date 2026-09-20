package security

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"testing"
)

// ANTI-DRIFT, the security.Policy counterpart of
// lifecycle.TestRenderedServicesHash_MatchesTheFilesAttachWrites. Write the
// drop-ins for REAL via the production writers, read the actual on-disk
// bytes, hash them, and compare against RenderedPolicyHash's output.
//
// `want` is built from os.ReadFile of the bytes the real writers put on
// disk — it never calls a render*DropInBody function itself. So a
// RenderedPolicyHash reimplementation that hashed the Policy struct's fields
// directly (instead of calling the same render functions the writers use)
// would diverge from `want` and fail here the moment any writer's rendered
// bytes are not a trivial restatement of its inputs — which is already true
// today (WriteCapabilityDropIn normalizes case and sorts before writing).
// That is the actual proof this test carries: the hash tracks written BYTES,
// not declared fields.
//
// The real residual gap is narrower than "hash tracks fields vs. render",
// and worth stating precisely rather than overclaiming: a future
// RenderedPolicyHash reimplementation that duplicated a writer's current
// template BYTE-FOR-BYTE inline (rather than calling render*DropInBody)
// would also pass this test today, then silently drift the next time that
// writer's template changes and the inline copy doesn't. This test cannot
// catch that duplication at the moment it's introduced — only structural
// review of "does RenderedPolicyHash call render*DropInBody" can. What this
// test DOES guarantee, unconditionally, is that today's implementation is
// correct against what's actually written to disk, and that any subsequent
// change to a render function's output is caught on the next run — a
// hand-duplicated inline copy is the one drift shape a passing run here is
// silent about.
func TestRenderedPolicyHash_MatchesTheDropInsWritersProduce(t *testing.T) {
	dir := withTempSystemdRoot(t)

	p := &Policy{
		Capabilities:   []string{"cap_chown", "CAP_NET_BIND_SERVICE"},
		SeccompProfile: "default",
		UserNamespace:  true,
	}
	unit := "powernode-m1-api.service"

	if err := WriteCapabilityDropIn(unit, p.Capabilities); err != nil {
		t.Fatalf("WriteCapabilityDropIn: %v", err)
	}
	if err := WriteSeccompDropIn(unit, p.SeccompProfile); err != nil {
		t.Fatalf("WriteSeccompDropIn: %v", err)
	}
	if err := WriteUserNamespaceDropIn(unit, p.UserNamespace); err != nil {
		t.Fatalf("WriteUserNamespaceDropIn: %v", err)
	}

	capBytes, err := os.ReadFile(filepath.Join(dir, unit+".d", "capabilities.conf"))
	if err != nil {
		t.Fatalf("read capabilities.conf: %v", err)
	}
	seccompBytes, err := os.ReadFile(filepath.Join(dir, unit+".d", "seccomp.conf"))
	if err != nil {
		t.Fatalf("read seccomp.conf: %v", err)
	}
	usernsBytes, err := os.ReadFile(filepath.Join(dir, unit+".d", "userns.conf"))
	if err != nil {
		t.Fatalf("read userns.conf: %v", err)
	}

	// Same construction RenderedPolicyHash uses: tag, NUL, body, NUL — see
	// its own write() closure. Order matches RenderedPolicyHash's own
	// component order (cap, then seccomp, then userns for this Policy shape
	// — no SELinux/AppArmor here, p declares neither).
	h := sha256.New()
	h.Write([]byte("cap"))
	h.Write([]byte{0})
	h.Write(capBytes)
	h.Write([]byte{0})
	h.Write([]byte("seccomp"))
	h.Write([]byte{0})
	h.Write(seccompBytes)
	h.Write([]byte{0})
	h.Write([]byte("userns"))
	h.Write([]byte{0})
	h.Write(usernsBytes)
	h.Write([]byte{0})
	want := hex.EncodeToString(h.Sum(nil))

	if got := RenderedPolicyHash(p, true); got != want {
		t.Fatalf("RenderedPolicyHash does not describe the written drop-in bytes:\n  hash    = %s\n  on disk = %s", got, want)
	}
}

// A capability-list edit that only changes CASE/ORDER — which
// WriteCapabilityDropIn normalizes and sorts away — must NOT move the hash:
// the writer produces byte-identical output for both, so a stamp that moved
// here would force a spurious re-attach on every no-op manifest edit.
func TestRenderedPolicyHash_StableUnderNormalizedEquivalentCapabilities(t *testing.T) {
	a := &Policy{Capabilities: []string{"cap_chown", "CAP_NET_BIND_SERVICE"}}
	b := &Policy{Capabilities: []string{"CAP_NET_BIND_SERVICE", "chown"}}

	if RenderedPolicyHash(a, true) != RenderedPolicyHash(b, true) {
		t.Fatal("hash moved for two capability lists that normalize to the identical rendered drop-in")
	}
}

// hasUnits=false must omit the per-unit components entirely, even when the
// Policy declares capabilities — a service-less module never reaches the
// per-unit drop-in loops in attachModule, so stamping them would describe
// bytes that are never written.
func TestRenderedPolicyHash_NoUnitsOmitsPerUnitComponents(t *testing.T) {
	withUnits := RenderedPolicyHash(&Policy{Capabilities: []string{"CAP_CHOWN"}, UserNamespace: true}, true)
	withoutUnits := RenderedPolicyHash(&Policy{Capabilities: []string{"CAP_CHOWN"}, UserNamespace: true}, false)

	if withoutUnits != "" {
		t.Fatalf("a service-less module should stamp empty when it declares only per-unit fields, got %q", withoutUnits)
	}
	if withUnits == withoutUnits {
		t.Fatal("precondition: the two cases should differ (capabilities present vs. hasUnits=false)")
	}
}

// A privileged module skips capabilities/MAC on the write path
// (attachModule's `if !policy.Privileged` gates) but still gets its
// user-namespace drop-in — PrivateUsers is orthogonal to the privileged
// opt-out. (Seccomp is a separate case, deliberately not covered by this
// test — see TestPolicyValidate_RejectsPrivilegedWithSeccomp and
// policy_stamp.go's own comment for why seccomp's gating differs.)
// RenderedPolicyHash must mirror the capabilities shape exactly: a Privileged
// policy's declared capabilities must never reach the stamp, because
// attachModule never writes a capabilities drop-in for it at all — unlike an
// UNPRIVILEGED policy with no capabilities, which still gets an
// empty-bounding-set drop-in written (attachModule's own comment: "we always
// write the drop-in for non-privileged modules even when the allowlist is
// empty"). So Privileged vs. unprivileged-with-no-caps are NOT expected to
// match — only Privileged-with-caps vs. Privileged-without-caps are, since
// Privileged suppresses the capabilities component entirely either way.
func TestRenderedPolicyHash_PrivilegedSuppressesCapabilitiesEntirely(t *testing.T) {
	privilegedNoCaps := RenderedPolicyHash(&Policy{Privileged: true, UserNamespace: true}, true)
	privilegedWithCaps := RenderedPolicyHash(&Policy{Privileged: true, Capabilities: []string{"CAP_CHOWN"}, UserNamespace: true}, true)

	if privilegedNoCaps != privilegedWithCaps {
		t.Fatal("a Privileged policy's declared capabilities must not reach the stamp — attachModule never writes them")
	}

	// And prove that's actually suppression, not coincidence: an
	// UNPRIVILEGED policy with the same (empty) capabilities differs, because
	// attachModule writes it an empty-bounding-set drop-in that a Privileged
	// module never gets.
	unprivilegedNoCaps := RenderedPolicyHash(&Policy{UserNamespace: true}, true)
	if privilegedNoCaps == unprivilegedNoCaps {
		t.Fatal("precondition: Privileged (writes no capabilities drop-in) should differ from unprivileged-with-no-declared-capabilities (writes an empty-bounding-set drop-in)")
	}
}

// Seccomp must contribute to the stamp EVEN WHEN Privileged is true — unlike
// capabilities, attachModule's seccomp write loop has no `!policy.Privileged`
// condition of its own (reconcile.go:1088 vs. the capability loop's gate at
// :1104). This Policy shape (Privileged + a declared SeccompProfile) cannot
// actually reach attachModule in production — Policy.Validate refuses it,
// see TestPolicyValidate_RejectsPrivilegedWithSeccomp — but RenderedPolicyHash
// runs on unvalidated manifests, and its own gating must match the write
// site literally rather than assume uniformity with capabilities/MAC. If a
// future edit nested seccomp inside RenderedPolicyHash's `if !p.Privileged`
// block (to "match" capabilities), this test is what would catch it.
func TestRenderedPolicyHash_SeccompNotGatedByPrivileged(t *testing.T) {
	privilegedNoSeccomp := RenderedPolicyHash(&Policy{Privileged: true}, true)
	privilegedWithSeccomp := RenderedPolicyHash(&Policy{Privileged: true, SeccompProfile: "default"}, true)

	if privilegedNoSeccomp == privilegedWithSeccomp {
		t.Fatal("a declared SeccompProfile must move the stamp even when Privileged is true — " +
			"attachModule's seccomp write loop has no !Privileged gate, and the stamp must match it literally")
	}
}

func TestRenderedPolicyHash_NilPolicy(t *testing.T) {
	if got := RenderedPolicyHash(nil, true); got != "" {
		t.Fatalf("nil policy should stamp empty, got %q", got)
	}
}

// hashResolvedProfileOrName: editing a resolved profile's CONTENT in place
// (same declared name) must move the hash — this is the file-based analogue
// of the renderer-parity guarantee above, since the "render" for a MAC
// profile is the file's own bytes rather than something the agent
// generates.
func TestHashResolvedProfileOrName_MovesWithFileContent(t *testing.T) {
	dir := t.TempDir()
	orig := SELinuxProfileDir
	SELinuxProfileDir = dir
	t.Cleanup(func() { SELinuxProfileDir = orig })

	path := filepath.Join(dir, "my-policy")
	if err := os.WriteFile(path, []byte("v1"), 0o644); err != nil {
		t.Fatal(err)
	}
	first := hashResolvedProfileOrName(SELinuxProfileDir, "my-policy")

	if err := os.WriteFile(path, []byte("v2"), 0o644); err != nil {
		t.Fatal(err)
	}
	second := hashResolvedProfileOrName(SELinuxProfileDir, "my-policy")

	if first == second {
		t.Fatal("hash did not move when the resolved profile's content changed under an unchanged declared name")
	}
}

// A profile name that doesn't resolve (never provisioned yet, or a
// containment violation) must still produce a deterministic, non-empty
// value rather than erroring the whole stamp computation — the real
// resolution failure surfaces separately when LoadSELinuxProfile /
// LoadAppArmorProfile attempt it inside Policy.Apply.
func TestHashResolvedProfileOrName_FallsBackToNameOnUnresolvable(t *testing.T) {
	dir := t.TempDir()
	orig := AppArmorProfileDir
	AppArmorProfileDir = dir
	t.Cleanup(func() { AppArmorProfileDir = orig })

	got := hashResolvedProfileOrName(AppArmorProfileDir, "never-provisioned")
	if got == "" {
		t.Fatal("an unresolvable profile name should still produce a non-empty fallback hash")
	}

	other := hashResolvedProfileOrName(AppArmorProfileDir, "also-never-provisioned")
	if got == other {
		t.Fatal("two different unresolvable names should not collide in the fallback")
	}
}
