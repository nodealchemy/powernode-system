# system-base

Minimal Ubuntu 24.04 LTS rootfs with systemd-networkd + openssh + powernode-agent runtime dependencies.

Every Powernode node depends on this module. It ships:

| File | Purpose |
|---|---|
| `/etc/systemd/network/10-dhcp.network` | DHCP on any `en*`/`eth*` interface; IPv6 RA enabled |
| `/etc/ssh/sshd_config.d/10-powernode.conf` | Pubkey-only sshd, no passwords, 60s keepalive |

## Build

```bash
# From the platform server (which knows the effective rsync_spec for a target):
mcp__powernode__platform_dispatch_to_runner \
  workflow=.gitea/workflows/build.yaml \
  inputs.module_id=<NodeModule.id> \
  inputs.rsync_spec=<server-computed>
```

## Catalog templates

This module is the foundation for every template in `node_module_catalog.rb`:
- `base` — system-base only
- `hardened` — system-base + security-hardening + chrony
- `web-apache` — hardened + apache
- `web-nginx` — hardened + nginx

## Protected paths

system-base claims a number of identity, authentication, and trust-boundary
paths via `protected_spec`. These are *guaranteed* to be the version
shipped by system-base — no higher-priority module's blob may carry them,
so a service module overlay can never silently shadow `/etc/shadow`,
`/etc/ssh/ssh_host_*_key`, `/etc/sudoers`, the powernode-agent service
unit, or the SUID trust-boundary binaries. See `manifest.yaml` for the
complete list and the project root `effective_mask` documentation for
how the build pipeline enforces them.

## License

MIT
