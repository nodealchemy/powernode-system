# security-hardening module

Baseline policy module — sysctl tunables, ulimits, kernel-module blacklist,
AppArmor + auditd. Priority 20 (above system-base, below services).

## Files shipped

- `/etc/sysctl.d/99-powernode-baseline.conf` — protected
- `/etc/security/limits.d/99-powernode-baseline.conf` — protected
- `/etc/modprobe.d/blacklist-powernode.conf` — protected

All three are on `protected_spec` because they define the floor that no
higher-priority service module may erode. Service modules that need a
relaxed setting (e.g. raising `net.core.somaxconn` for a high-throughput
web tier, or loading `usb-storage` for a backup appliance) must do so via
a dependant child module (`parent_module_id` set to this module). That
override goes through the operator's explicit approval surface, with the
deviation recorded in fleet audit.

## Why this is its own module

system-base ships the *binaries* (sysctl, modprobe, apparmor_parser).
This module ships only the *policy*. Splitting the two means:

- A node can run system-base alone for break-glass debugging.
- The hardening policy can version, promote, and roll back independently
  of base-OS updates.
- Promotion gates can require a hardened SBOM (e.g. for staging→live)
  without entangling base-OS releases.
