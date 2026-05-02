# system-base

Minimal Ubuntu 24.04 LTS rootfs with systemd-networkd + openssh + powernode-agent runtime dependencies.

Every Powernode smoke node depends on this module. It ships:

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

## Smoke testing

This module is referenced by all three smoke templates:
- `smoke-base` — system-base only
- `smoke-web-apache` — system-base + apache
- `smoke-web-nginx` — system-base + nginx

## License

MIT
