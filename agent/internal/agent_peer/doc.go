// Package agent_peer implements the NodeInstance-as-Agent pattern: each
// NodeInstance can register itself as a peer that other agents (and the
// platform's AI fleet) can address by handle.
//
// Status: Phase 6 (in active sweep per docs/TASKS.md). Registrar implementation
// shipped; cross-agent task delegation flow incomplete pending the matching
// platform-side mirror service (PeerAgentMirror — see memory
// project_ai_agent_type_allow_list).
//
// # Concept
//
// Once registered, a NodeInstance has a handle like `@instance-edge-tokyo-01`
// addressable from other agents' workspaces. Capabilities are declared in
// the node's manifest (SSH access, k3s-admin, docker-admin, etc.); other
// agents discover via `platform.discover_skills`.
//
// # Key types
//
//   Registrar     — registers + de-registers the NodeInstance as a peer at
//                   runtime startup / shutdown
//   Capabilities  — declared capability set (SSH, kubectl, docker, etc.)
//   Manifest      — full peer manifest posted to /api/v1/system/node_api/peer
//
// Server-side counterpart: extensions/system/server/app/services/system/
// peer_agent_mirror.rb (mirrors the agent registration into Ai::Agent rows
// with metadata.kind=system_node_peer).
package agent_peer
