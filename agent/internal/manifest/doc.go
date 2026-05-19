// Package manifest fetches + caches NodeModule manifests on the agent
// side so the reconciler + CLI work air-gapped after a successful
// fetch.
//
// # On-disk cache
//
// DefaultRoot = /persist/var/lib/powernode/modules
//
// Lives under /persist so cached manifests survive reboots. Reconcile +
// CLI commands prefer cached copies and only re-fetch when explicitly
// asked or when a known cache-bust signal fires.
//
// # Pipeline shape
//
//	FetchAndCache(client, moduleID, root) → manifest
//	  ↓
//	transport.Client.GetJSON(/api/v1/system/node_api/modules/:id/manifest)
//	  ↓
//	parse JSON → fsutil.AtomicWrite(<root>/<moduleID>.json)
//	  ↓
//	return parsed manifest.Manifest
//
// # Key types
//
//	Client    — minimal interface (GetJSON); satisfied by transport.Client
//	Manifest  — the parsed module manifest (mirrors the
//	            system_modules.manifest_json server-side column shape;
//	            see types.go for the field set)
//
// Decoupling from transport lets tests stub without an httptest server.
package manifest
