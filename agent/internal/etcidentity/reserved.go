package etcidentity

// ReservedUIDs / ReservedGIDs mirror the Ruby
// System::Identity::ReservedIdentities constant. Used here only for
// sanity assertions — the platform is the authoritative allocator, so
// if a manifest's user/group lands at a UID that doesn't match this
// table, the agent logs but trusts the platform's value.
//
// Keep in sync with extensions/system/server/app/services/system/
// identity/reserved_identities.rb. Drift here doesn't break anything
// (server is authoritative) but loses the cross-check benefit.
var ReservedUIDs = map[string]int{
	// Databases (70100..70199)
	"postgres":      70110,
	"mysql":         70120,
	"mariadb":       70121,
	"mongodb":       70130,
	"redis":         70140,
	"memcached":     70150,
	"cassandra":     70160,
	"elasticsearch": 70170,
	"influxdb":      70180,
	"cockroachdb":   70190,
	// Web servers (70200..70299)
	"nginx":    70210,
	"www-data": 70220,
	"caddy":    70230,
	"traefik":  70240,
	"haproxy":  70250,
	"varnish":  70260,
	// Messaging (70300..70399)
	"rabbitmq": 70310,
	"nats":     70320,
	"kafka":    70330,
	"pulsar":   70340,
	// Observability (70400..70499)
	"prometheus": 70410,
	"grafana":    70420,
	"loki":       70430,
	"tempo":      70440,
	"jaeger":     70450,
	"vector":     70460,
	"fluentbit":  70470,
	// CI/CD (70500..70599)
	"gitea":      70510,
	"jenkins":    70520,
	"woodpecker": 70530,
	"drone":      70540,
	// Platform infra (70600..70699)
	"vault":     70610,
	"consul":    70620,
	"etcd":      70630,
	"powernode": 70690,
	// App runtimes (70700..70799)
	"tomcat":   70710,
	"wildfly":  70720,
	"puma":     70730,
	"unicorn":  70740,
	"gunicorn": 70750,
	// Baseline/system fixed-uid accounts — NOT part of the 70xxx
	// allocator range. Listed here only so this cross-check table
	// stays complete; the authoritative definition is
	// etcidentity.Baseline() in baseline.go.
	"pnadmin": 1000,
}

// ReservedGIDs mirror ReservedUIDs (every reserved user gets a same-
// name primary group at the same numeric value).
var ReservedGIDs = ReservedUIDs
