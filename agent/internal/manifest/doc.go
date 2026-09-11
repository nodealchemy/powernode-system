// Package manifest fetches + caches NodeModule manifests on the agent
// side so the reconciler + CLI work air-gapped after a successful
// fetch.
//
// # On-disk cache
//
// DefaultRoot = /persist/var/lib/powernode/modules
//
// One file per module, <root>/<id>/manifest.json, under /persist so cached
// manifests survive reboots. LoadOrFetch prefers the cached copy and
// re-fetches only when it is missing, does not decode, or is older than
// the caller's staleAfter (0 means never stale).
//
// # Pipeline shape
//
//	FetchAndCache(client, root, moduleID) → manifest
//	  ↓
//	transport.Client.GetJSON(/api/v1/system/node_api/modules/:id)
//	  ↓
//	unwrap the {success, data} envelope → fsutil.AtomicWriteJSON(<root>/<id>/manifest.json)
//	  ↓
//	return parsed manifest.Manifest
//
// A failed cache write still returns the fetched manifest, alongside the
// error.
//
// # Key types
//
//	Client    — minimal interface (GetJSON); satisfied by transport.Client
//	Manifest  — the parsed module manifest (see types.go for the field set)
//
// Decoupling from transport lets tests stub without an httptest server.
package manifest
