// Package security applies the agent's local hardening posture: capability
// dropping, MAC profiles, egress filtering, and per-process security policy.
//
// Runs at agent startup (in the `service` subcommand) before any module
// reconcile, so the agent itself runs under restricted privileges before
// touching user-supplied module content.
//
// # Sub-modules
//
//   - capabilities.go  drops Linux capabilities not needed for this agent's
//                      role (e.g., CAP_NET_ADMIN required for sdwan; CAP_SYS_ADMIN
//                      retained briefly for mount, dropped after switch_root)
//
//   - mac.go           applies AppArmor / SELinux profile (when present);
//                      the security-hardening module supplies the profile via
//                      file_spec, agent loads + enforces at boot
//
//   - egress.go        installs nftables rules limiting outbound traffic to
//                      the platform's API + the OCI registry; prevents
//                      compromised modules from making arbitrary outbound
//                      connections
//
//   - policy.go        loads + enforces per-NodeInstance policy received from
//                      the platform (e.g., disable SSH, restrict to TLS-only)
//
// # Key types
//
//   Profile              — capability set + MAC profile + egress rules
//   PolicyDecision       — { Allowed bool, Reason string }
//
// Aligns with the parent platform's threat-model.md (STRIDE analysis across
// the operator API, worker API, node API, MCP tools, internal CA).
package security
