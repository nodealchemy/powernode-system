// Package security applies a module's manifest.yaml `security:` block on the
// running node: capability dropping, SELinux/AppArmor profile loading, seccomp
// filter compilation, egress allowlist enforcement, and user-namespace
// drop-ins.
//
// Every operation goes through the mount.Runner abstraction, so unit tests can
// verify command shape without root or kernel features.
//
// # Files
//
//   - capabilities.go  capability drop-ins (WriteCapabilityDropIn,
//     WriteAmbientCapabilityDropInAt) and the KnownCapabilities set
//   - mac.go           AppArmor / SELinux profile loading; returns
//     ErrAppArmorNotAvailable / ErrSELinuxNotAvailable when
//     the host lacks the LSM
//   - egress.go        nftables allowlist in the EgressTable chain, plus
//     UnionEgressPolicy for combining several modules' policies
//   - seccomp_profile.go  seccomp set validation (KnownSeccompSets) and the
//     unit drop-in that points systemd at the profile
//   - userns_dropin.go PrivateUsers drop-in
//   - policy.go        the Policy type itself
//
// # Key types
//
//	Policy  — the module-level policy declared in manifest.yaml#security:
//	          capabilities, MAC profile, seccomp set, egress allowlist.
//	          Applied at module attach time.
//
// This package exports functions rather than an applier object: there is no
// Profile aggregate and no PolicyDecision result type — a refusal is a plain
// error, and there is no allow/deny evaluator here at all.
//
// Reference: Golden Eclipse plan Security Architecture (Module-Level Security);
// module manifest.yaml security block schema.
package security
