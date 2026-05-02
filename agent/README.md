# System Agent (`ipn-agent`)

The on-node runtime for Powernode-managed instances. Lives inside the
System extension at `extensions/system/agent/` (Golden Eclipse rule: all
system-related code belongs in the System extension). Replaces the legacy
bash `ipn` script with a static Go binary embedded in the initramfs.

## Status

**M2.A — project skeleton landed (2026-04-30).** Subcommand surface defined;
internal/identity package implemented (cmdline + virtio-fw-cfg + local
identity.cfg strategies + Resolver); other internal packages stubbed.
Subsequent Golden Eclipse milestones fill in the rest:

- M2.B — identity strategies (cloud metadata: AWS, GCP, Azure, DigitalOcean) → adds aws/gcp/azure files in `internal/identity/`
- M2.C — enrollment client (CSR generation + mTLS handshake with `/node_api/enroll`) → `internal/enroll/`
- M2.D — composefs + overlayfs mount orchestration → `internal/mount/`
- M2.E — long-lived service mode (heartbeat + task lease + cert rotate) → `internal/runtime/`

## Subcommand surface

```
ipn-agent boot           first-boot (initramfs init-bottom path)
ipn-agent service        long-lived loop
ipn-agent enroll         token → mTLS cert exchange
ipn-agent verify <path>  cosign + fs-verity verification
ipn-agent introspect     print agent's view of self
ipn-agent attach <id>    mount module into union (legacy ipn -a)
ipn-agent detach <id>    unmount module (legacy ipn -d)
ipn-agent update         reconcile with /node_api/modules (legacy ipn -u)
ipn-agent commit <id>    capture live delta + push (legacy ipn -c)
ipn-agent status         module attach/detach state (legacy ipn -s)
ipn-agent exec <id>      fetch + run NodeScript (legacy ipn -e)
ipn-agent sync           reconcile cycle (legacy ipn -S)
ipn-agent init <id> <a>  module init action (legacy ipn -I)
ipn-agent volume-setup   partition disks (legacy ipn -X)
ipn-agent puppet apply   puppet integration (legacy ipn -p)
ipn-agent version        build info
```

## Build

Requires Go 1.22+. CGO disabled (static binary).

```sh
make build           # cross-compiles amd64 + arm64 to dist/
make test            # go test -race ./...
make lint            # golangci-lint run
```

CI builds via `.gitea/workflows/build.yaml` on push + PR; releases on tag
push (signed with cosign keyless via Sigstore Fulcio).

## Reference

- Plan: `~/.claude/plans/we-are-working-on-golden-eclipse.md` (M2)
- Legacy: `~/Drive/Projects/powernode-bootstrap/scripts/{ipn,ipn_functions,ipn_initialize}`
- Platform endpoints (mTLS-authenticated): `extensions/system/server/app/controllers/api/v1/system/node_api/`
- Memories: `project_golden_eclipse.md`, `project_credential_pattern.md`
