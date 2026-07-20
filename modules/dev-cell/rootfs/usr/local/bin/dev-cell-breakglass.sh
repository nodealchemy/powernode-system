#!/bin/sh
# dev-cell-breakglass.sh — durably re-materializes the operator break-glass
# sudo drop-in for `powernode-agent.service` on every boot.
#
# The agent's own etcsudoers.ApplyOperatorBreakGlass (see
# agent/internal/etcsudoers/breakglass.go) writes the actual
# `pnadmin ALL=(ALL) NOPASSWD: ALL` sudoers rule, gated on the
# POWERNODE_OPERATOR_BREAK_GLASS env var being set on the AGENT's OWN
# process at startup -- but that check only runs once, at agent boot, and
# only reads its OWN process environment. It has no mechanism of its own
# to durably set that env var across reboots. This script is that
# mechanism, scoped to dev-cell: `/etc` is EPHEMERAL on this pivot-composed
# appliance (overlay upper, wiped every shutdown), so anything written
# there -- including a systemd drop-in -- must be re-written every boot by
# something that itself runs every boot. `powernode-agent.service` has no
# ConditionPathExists=!/persist/... marker gating dev-cell's `bootstrap`-
# style units, so a unit shaped like this one (no persist marker, runs
# every boot) is the right fit; dev-cell-provision.sh is NOT (it is
# gated to run exactly once, ever, so anything it wrote to /etc would
# vanish for good on the very next reboot).
#
# A dev-cell is explicitly a dev/recovery-loop instance (see this
# module's manifest.yaml description + breakglass.go's own doc comment,
# "Intended for dev/recovery loops on managed_child instances where the
# pnadmin user otherwise has no path to root") -- unlike claude-tmux's
# `claude` session, dev-cell's whole point is a real interactive
# development environment the operator logs into directly, so pnadmin
# needs sudo to actually work the box.
#
# Ordering note: this only takes effect from the NEXT agent start onward
# -- by the time ANY dev-cell unit runs, `powernode-agent.service` (the
# very thing that composed + started dev-cell in the first place) is
# already running without this drop-in. This script does not restart the
# agent itself (racing a restart against the same process still mid-
# orchestrating this boot is worse than a one-boot delay); the effect
# lands on the node's next reboot or an operator-issued
# `systemctl restart powernode-agent.service`.
set -eu

DROPIN_DIR=/etc/systemd/system/powernode-agent.service.d
DROPIN_FILE="$DROPIN_DIR/dev-cell-breakglass.conf"
BODY='[Service]
Environment=POWERNODE_OPERATOR_BREAK_GLASS=1
'

mkdir -p "$DROPIN_DIR"

if [ -f "$DROPIN_FILE" ] && [ "$(cat "$DROPIN_FILE")" = "$BODY" ]; then
  exit 0
fi

printf '%s' "$BODY" > "$DROPIN_FILE"
chmod 644 "$DROPIN_FILE"
systemctl daemon-reload
