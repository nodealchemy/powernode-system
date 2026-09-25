package security

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"strings"
)

// RenderedPolicyHash is the security.Policy analogue of
// lifecycle.RenderedServicesHash: it stamps what agent/internal/runtime's
// attachModule (reconcile.go) will actually WRITE or APPLY for a module's
// resolved Policy on the cloud-init hot-reconcile path, so a change confined
// entirely to a manifest's `security:` block — one that leaves every
// rendered unit body byte-identical — still moves the re-attach stamp
// (IMP-f5c0afa7183a, the "attachStamp only covers unit bodies" defect).
//
// It is deliberately NOT a hash of the Policy struct's fields. Two policies
// with identically-EFFECTIVE fields (different capability name casing, a
// different declaration order) must hash identically, because
// WriteCapabilityDropIn normalizes and sorts before it ever touches disk —
// hashing the raw fields would move the stamp on a no-op manifest edit. The
// reverse must also hold: a future fix to how a writer RENDERS its bytes
// (name normalization, directive ordering, the template) must move this
// hash even with the Policy fields held fixed, which is exactly the shape
// of defect IMP-01a05efa closed for unit bodies and re-opened here if this
// hashed the fields instead of the render. So every component below calls
// the SAME pure render function (renderCapabilityDropInBody /
// renderSeccompDropInBody / renderUserNamespaceDropInBody) the corresponding
// writer uses to produce its file bytes — one render, two consumers, same
// relationship RenderUnitModeGraph has to RenderedServicesHash.
//
// hasUnits distinguishes the two write shapes attachModule uses for a
// module's security block:
//   - capabilities / seccomp / user-namespace drop-ins are written PER UNIT
//     (reconcile.go's `for _, unit := range mf.UnitNames()` loops) — a
//     module with zero units gets zero drop-in writes regardless of what its
//     Policy contains, so these three components are omitted entirely when
//     hasUnits is false. Their rendered bytes never vary by unit or root —
//     none of the three drop-in bodies reference the unit name or a root
//     path — so hashing the render once per module (not once per unit) is
//     exact, not an approximation.
//   - SELinux/AppArmor profile loading is PER MODULE: Policy.Apply calls
//     loadMACProfile unconditionally, before any per-unit loop, so these two
//     always participate when declared — hasUnits or not.
//
// Returns "" when nothing described above would be written or applied at
// all, mirroring RenderedServicesHash's own "no rendered output to
// describe" contract for a service-less module.
func RenderedPolicyHash(p *Policy, hasUnits bool) string {
	if p == nil {
		return ""
	}
	var units []UnitCapabilities
	if hasUnits {
		units = []UnitCapabilities{{Allow: p.Capabilities}}
	}
	return RenderedPolicyHashForUnits(p, units)
}

// RenderedPolicyHashForUnits is RenderedPolicyHash for per-service
// capabilities (IMP-caef5c00d63f): `units` carries each unit's RESOLVED
// capability set — the exact list attachModule hands WriteCapabilityDropIn for
// that unit — so a change confined to one service's own capabilities key moves
// the stamp. RenderedPolicyHash above is the module-wide special case (every
// unit gets p.Capabilities).
//
// When every unit renders the same capability drop-in, the component is
// written ONCE under the plain "cap" tag, byte-for-byte what the module-wide
// hash always wrote, so a module that declares no per-service keys keeps the
// stamp it already had. Only when units differ is each unit's body written
// under its own "cap:<unit>" tag, in declaration order.
func RenderedPolicyHashForUnits(p *Policy, units []UnitCapabilities) string {
	if p == nil {
		return ""
	}
	hasUnits := len(units) > 0

	h := sha256.New()
	wrote := false
	write := func(tag, s string) {
		wrote = true
		h.Write([]byte(tag))
		h.Write([]byte{0})
		h.Write([]byte(s))
		h.Write([]byte{0})
	}

	// Mirrors attachModule's own write-time gates (reconcile.go) LITERALLY,
	// per component, rather than assuming they're uniform:
	//   - capabilities and MAC (SELinux/AppArmor) ARE gated on `!p.Privileged`
	//     at the write site, so they are gated on it here too.
	//   - seccomp is NOT. attachModule's seccomp loop is gated only on
	//     `policy.SeccompProfile != ""` — there is no `!p.Privileged` check at
	//     that call site at all, unlike the capability loop directly below it.
	//     A Privileged policy can never actually REACH this case today,
	//     because Policy.Validate (policy.go) refuses a Privileged policy that
	//     also declares SeccompProfile — but that refusal lives in a different
	//     file, is not enforced here, and attachStamp runs on manifests that
	//     have not been validated yet. Gating seccomp on `!p.Privileged` here
	//     as well would make the stamp diverge from the write site the
	//     instant that Validate coupling is ever relaxed — silently
	//     re-introducing this exact defect class for seccomp specifically.
	//     See TestPolicyValidate_RejectsPrivilegedWithSeccomp, which pins the
	//     coupling this reasoning depends on.
	if !p.Privileged {
		if hasUnits {
			tags := make([]string, len(units))
			bodies := make([]string, len(units))
			uniform := true
			for i, u := range units {
				if body, err := renderCapabilityDropInBody(u.Allow); err == nil {
					tags[i], bodies[i] = "cap", body
				} else {
					// Unresolvable (unknown capability name): fall back to the raw
					// declared list so the comparison still moves on any edit to it,
					// rather than erroring the stamp computation itself. The real
					// failure surfaces separately when attachModule's own Validate
					// (or the per-service resolver) runs the same check.
					tags[i], bodies[i] = "cap-unresolved", strings.Join(u.Allow, ",")
				}
				if tags[i] != tags[0] || bodies[i] != bodies[0] {
					uniform = false
				}
			}
			if uniform {
				write(tags[0], bodies[0])
			} else {
				for i, u := range units {
					write(tags[i]+":"+u.Unit, bodies[i])
				}
			}
		}

		if p.SELinuxProfile != "" {
			write("selinux", hashResolvedProfileOrName(SELinuxProfileDir, p.SELinuxProfile))
		}
		if p.AppArmorProfile != "" {
			write("apparmor", hashResolvedProfileOrName(AppArmorProfileDir, p.AppArmorProfile))
		}
	}

	if hasUnits && p.SeccompProfile != "" {
		if body, err := renderSeccompDropInBody(p.SeccompProfile); err == nil {
			write("seccomp", body)
		} else {
			write("seccomp-unresolved", p.SeccompProfile)
		}
	}

	// UserNamespace is written per-unit but unconditionally — including for
	// Privileged modules (WriteUserNamespaceDropIn's own doc: PrivateUsers is
	// orthogonal to the privileged capability/MAC opt-out) — so it is the one
	// component gated on hasUnits alone, never on Privileged.
	if hasUnits {
		write("userns", renderUserNamespaceDropInBody(p.UserNamespace))
	}

	if !wrote {
		return ""
	}
	return hex.EncodeToString(h.Sum(nil))
}

// hashResolvedProfileOrName hashes the CONTENT of the resolved agent-owned
// profile file at dir/name — the file-based analogue of RenderedPolicyHash's
// other components hashing rendered BYTES rather than manifest-declared
// values, so editing a profile's content in place (same declared name,
// different bytes) moves the hash the same way a corrected drop-in renderer
// would.
//
// Falls back to hashing the bare NAME on any resolution or read failure
// (missing profile, containment violation, unreadable file) rather than
// erroring. This costs precision — a name-only comparison still catches a
// changed declaration, just not a changed file behind an unchanged
// declaration — but never masks the underlying problem: the identical
// resolution failure surfaces loudly and separately when LoadSELinuxProfile
// / LoadAppArmorProfile attempt it for real inside Policy.Apply.
func hashResolvedProfileOrName(dir, name string) string {
	if resolved, err := resolveAgentOwnedProfile(dir, name); err == nil {
		if content, err := os.ReadFile(resolved); err == nil {
			sum := sha256.Sum256(content)
			return "content:" + hex.EncodeToString(sum[:])
		}
	}
	sum := sha256.Sum256([]byte(name))
	return "name:" + hex.EncodeToString(sum[:])
}
