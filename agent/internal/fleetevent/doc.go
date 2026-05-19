// Package fleetevent posts agent-side events to the platform's
// /api/v1/system/node_api/fleet/events endpoint.
//
// # Usage sites
//
//   - the long-loop reconciler (module.attached, module.detached)
//   - cert rotation (cert.rotated)
//   - the operator CLI (script.executed, volume.provisioned, etc.)
//
// # Pipeline integration
//
// Events flow into the same Fleet::EventBroadcaster pipeline that trading
// + system autonomy already use, so the agent's view appears in the
// unified activity feed. Reference:
// extensions/system/server/app/services/system/fleet/event_broadcaster.rb.
//
// # Key types
//
//	Emitter   — wraps an HTTPClient and posts JSON events
//	HTTPClient — minimal interface (PostJSON); satisfied by transport.Client
//	            and transport.SwappableClient
//
// Decoupling from transport lets tests stub without an httptest server.
package fleetevent
