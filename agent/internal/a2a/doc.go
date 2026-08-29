// Package a2a implements the on-node agent-to-agent (A2A) transport for the
// AI/MCP workload substrate (L2.5/L3).
//
// Each agent-instance runs a small MCP JSON-RPC 2.0 server (server.go) over
// mTLS so OTHER instances can invoke its registered skills, and an MCP client
// (client.go) to call peers. Authorization is by signed CAPABILITY TOKEN
// (verifier.go): the platform mints an Ed25519-signed token for the caller
// (proving "A may invoke skill S on B") and delivers it server-side in the
// a2a_call task payload — the caller never requests one over MCP, which
// refuses precisely because a tool result is persisted and forwarded to the
// model provider (IMP-27cc7dceb97b). The caller presents the token on the
// call, and the callee verifies the signature OFFLINE against the platform's
// advertised public key — no per-call platform round-trip.
//
// Trust model (mirrors the SDWAN membership-credential system):
//   - Transport identity: mTLS. The caller presents its NodeInstance client
//     cert (CN = instance id), verified against the platform CA. So the callee
//     knows WHO is connecting at the transport layer.
//   - Capability: the Ed25519 token. The callee checks token.sub == the mTLS
//     CN (the connector is the grantee), token.aud == self, token.skill == the
//     tool being called, and the time window. Both must hold.
//
// The verifier here mirrors internal/sdwan/mc_verifier.go (same Ed25519 +
// trusted-key-by-handle + clock-skew shape); the signer is the platform's
// System::PeerCapabilityTokenSigner.
package a2a
