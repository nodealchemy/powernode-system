// Package migration is the agent-side executor for System::StorageMigration,
// which moves a volume's data from a source binding to a target binding. The
// platform plans and approves a migration; Runner picks up the ones assigned
// to this node from /api/v1/system/node_api/storage_migrations, advances each
// on every Tick, and reports each transition back.
//
// It does NOT run the platform's multi-hop workload migration chains
// (System::MigrationChain). A previous revision of this comment said it did;
// nothing in this package reads a chain.
//
// # Forward steps
//
// The contract (server-side plan["agent_contract"]):
//
//	mount_target → snapshot → rsync → verify → cutover → unmount_source
//
// mapped onto the StorageMigration states:
//
//	approved  → preparing  (mount source + target)
//	preparing → syncing    (rsync data)
//	syncing   → verifying  (rsync --checksum --dry-run; expect no diffs)
//	verifying → cutover
//	cutover   → completed  (re-point the consumer's mount; the agent reports)
//
// Cutover stops the consumer's units, remounts its canonical mount point on
// the target, restarts the units and releases the scratch mounts. A
// migration that names no consumer mount point or units only unmounts the
// source scratch.
//
// # Intents
//
// Two platform requests are checked before the status: RevertRequested
// re-points the consumer back to the source (cutover in reverse), and
// CleanupRequested deletes the target-side scratch artifacts, never the
// source. Cleanup refuses any binding whose effective subpath is empty,
// which would otherwise mount, and empty, the export root.
//
// # Key types
//
//	Runner             — Tick fetches the assigned migrations and advances each
//	AssignedMigration  — one migration, as the node API serializes it for the agent
//	Client             — the GetJSON / PostJSON surface Runner needs
//
// Tick is idempotent: a re-run picks up from the status the platform
// reports, and one migration's error does not stop the others.
//
// Plan reference: E8.2 / E8.3.
package migration
