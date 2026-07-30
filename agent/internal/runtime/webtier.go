package runtime

// webTierModuleNames are the composed modules whose presence means "this node
// serves the platform's own web tier", and can therefore answer the loopback
// /up probe.
//
// A fleet-global list of MODULE NAMES is safe in a way that a fleet-global URL
// is not, and that distinction is the whole design. The SiteSetting this
// replaces delivered one URL to every node's envelope, so protecting a hub with
// it re-imposed an unanswerable loopback probe on the entire fleet. A name list
// is evaluated against each node's OWN composed set, so it selects the strong
// gate exactly where the strong gate can be met and nowhere else — per-node by
// construction, with nothing to configure and nothing to get wrong.
//
// It also reaches the one node that needs it most. A self-hosted control plane
// never live-fetches pre-pivot; it boots from a permanently frozen LKG, so a
// server-side setting can never arrive. The frozen breadcrumb still lists the
// modules it composed, which is why detection reads that and not the platform.
//
// The names are the honest cost here. A module declaring its own health
// endpoint in its manifest would be better, and is the right long-term shape —
// but Manifest is only populated on the breadcrumb for data-file modules, so it
// cannot be relied on today, least of all in an LKG frozen before any such
// field existed. Name is populated at both breadcrumb construction sites.
// BOTH are required, and getting this wrong is not a near-miss — it hands a
// whole node class a gate it can never answer, which is the exact bug this
// change exists to remove.
//
// The probe URL is https://127.0.0.1/up, and that path is Traefik on :443 →
// hub-backend Rails. Keying only on the module that SERVES /up ignores the
// module that TERMINATES the port. The powernode-hub-worker template composes
// hub-backend without a reverse proxy — its seed description says so outright,
// "No reverse-proxy (no public TLS endpoint on workers)" — so every worker-pool
// node would have been handed a loopback probe with nothing listening, failed
// it for the entire boot, and silently reverted good images. Those nodes bless
// correctly today on the local gate, so that would have been a regression
// introduced by the fix, not a gap it failed to close.
//
// Requiring both keeps powernode-hub, powernode-hub-api and the cluster members
// detected, and correctly excludes powernode-hub-frontend (Traefik but no
// Rails — it cannot answer a Rails route either).
const (
	webTierAppModule   = "powernode-hub-backend"
	webTierProxyModule = "reverse-proxy-traefik"
)

// servesWebTier reports whether the composed set can answer the loopback /up
// probe: it needs the app that serves the route AND the proxy that terminates
// the port.
func servesWebTier(mods []LKGModule) bool {
	return hasModule(mods, webTierAppModule) && hasModule(mods, webTierProxyModule)
}

func hasModule(mods []LKGModule, name string) bool {
	for _, m := range mods {
		if m.Name == name {
			return true
		}
	}
	return false
}
