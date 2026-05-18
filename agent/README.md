# System Agent (`powernode-agent`)

The on-node runtime for Powernode-managed instances. Single static Go
binary (~20MB), CGO disabled, embedded in the initramfs. Replaces the
legacy bash `ipn` script.

## Build

Requires Go 1.22+.

```sh
go mod tidy                # update go.sum
make build                 # cross-compile amd64 + arm64 to dist/
make build-amd64           # amd64 only (faster local iteration)
make test                  # go test -race ./...
make lint                  # golangci-lint run
```

CI builds via `.gitea/workflows/build.yaml` on push + PR; releases on tag
push (signed with cosign keyless via Sigstore Fulcio).

## Subcommand surface

```
powernode-agent boot             # first-boot (initramfs init-bottom path)
powernode-agent service          # long-lived loop (30s heartbeat + task lease)
powernode-agent enroll           # token → mTLS cert exchange
powernode-agent verify <path>    # cosign + fs-verity verification
powernode-agent introspect       # print agent's view of self
powernode-agent attach <id>      # mount module into union (legacy ipn -a)
powernode-agent detach <id>      # unmount module (legacy ipn -d)
powernode-agent update           # reconcile with /node_api/modules (legacy ipn -u)
powernode-agent commit <id>      # capture live delta + push (legacy ipn -c)
powernode-agent status           # module attach/detach state (legacy ipn -s)
powernode-agent exec <id>        # fetch + run NodeScript (legacy ipn -e)
powernode-agent sync             # reconcile cycle (legacy ipn -S)
powernode-agent init <id> <act>  # module init action (legacy ipn -I)
powernode-agent volume-setup     # partition disks (legacy ipn -X)
powernode-agent puppet apply     # puppet integration (legacy ipn -p)
powernode-agent version          # build info (git SHA + go version)
```

## Internal packages

23 packages under `internal/`, each a focused domain unit. For the
package-by-package reference (responsibilities, lifecycle, fw-cfg
cascade, heartbeat protocol, module-fetch sequence, cert rotation), see
**[`docs/agent-internals.md`](../docs/agent-internals.md)**.

Brief summary by domain:

- **Identity + enrollment**: `identity`, `enroll`
- **Transport + security**: `transport`, `security`, `verify`
- **Storage + mounting**: `fsutil`, `mount`, `oci`, `storage`
- **Runtime services**: `runtime`, `lifecycle`, `boot`, `systemd`
- **Module + manifest**: `manifest`, `migration`
- **Runtime integrations**: `dockerd`, `k3sd`
- **Networking**: `sdwan`, `tcpfwd`
- **Federation + peering**: `agent_peer`, `federation`
- **Operator-facing**: `acme`, `fleetevent`

## Reference

- [`docs/agent-internals.md`](../docs/agent-internals.md) — package-by-package internals reference
- [`docs/ARCHITECTURE.md`](../docs/ARCHITECTURE.md) §2 — design-level overview
- [`docs/SMOKE_TEST.md`](../docs/SMOKE_TEST.md) Pass 1 — boot chain validation
- [`docs/tutorials/01-first-boot.md`](../docs/tutorials/01-first-boot.md) — first-time tutorial that exercises the agent end-to-end
- Platform endpoints (mTLS-authenticated): `extensions/system/server/app/controllers/api/v1/system/node_api/`
- Memory: `project_credential_pattern.md`
