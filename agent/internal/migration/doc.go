// Package migration runs agent-side migration steps from the platform's
// System::Migrations job system. The platform composes a migration plan
// (multi-hop chain of source → intermediate → destination steps); each
// step on this node is materialized here as a stateful runner that
// reports progress + final outcome back via the worker API.
//
// # Operator-facing model
//
// Migration is the platform-wide pattern for moving workloads across
// nodes / regions / clusters / accounts. See:
//
//   - extensions/system/server/app/models/system/migration_chain.rb
//   - extensions/system/server/app/services/system/migrations/
//   - docs/federation/MIGRATION_DEVELOPER_GUIDE.md
//
// # Key types
//
//	Runner — owns a single in-flight migration step:
//	  - source node: snapshot + ship
//	  - destination node: apply + verify
//	  - intermediate: pass-through with checkpoints
//
// # Reference
//
// Plan P9.5 — multi-hop migration chains. The runner here is the
// agent-side worker that actually moves bytes; chain composition +
// approval gates live in the platform.
package migration
