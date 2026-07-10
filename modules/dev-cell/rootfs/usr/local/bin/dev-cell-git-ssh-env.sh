# dev-cell-git-ssh-env.sh — resolves GIT_SSH_COMMAND for the per-repo SSH
# deploy key dev-cell-bootstrap.sh stages in tmpfs. Shared by
# dev-cell-provision.sh (initial clone) and dev-cell-executor.sh (every
# loop-branch push) so the fail-closed known_hosts check below has exactly
# ONE implementation, not two copies that could silently drift apart.
#
# MUST BE SOURCED, not executed (". dev-cell-git-ssh-env.sh"): it exports
# GIT_SSH_COMMAND into the CALLING shell. Running it as a subprocess would
# set the variable in a throwaway subshell and silently do nothing.
#
# Reads the deploy key + known_hosts FRESH from tmpfs on every call — never
# cached to a file outside $DEV_CELL_RUNTIME_DIR — so a re-provisioned or
# rebooted cell always picks up the current boot's bundle.
#
# FAIL-CLOSED: an empty known_hosts (DevCellBootstrapService#known_hosts_for
# returns "" when the platform has no Gitea host key on record) refuses to
# proceed rather than falling back to StrictHostKeyChecking=no, which would
# accept ANY host key presented (MITM). Set DEV_CELL_ALLOW_TOFU=1 to
# explicitly opt into trust-on-first-use (accept-new) instead of failing.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  echo "dev-cell-git-ssh-env.sh: must be sourced (. dev-cell-git-ssh-env.sh), not executed" >&2
  exit 1
fi

: "${DEV_CELL_RUNTIME_DIR:=/run/dev-cell}"
DEV_CELL_DEPLOY_KEY="$DEV_CELL_RUNTIME_DIR/deploy_key"
DEV_CELL_KNOWN_HOSTS="$DEV_CELL_RUNTIME_DIR/known_hosts"

if [ ! -s "$DEV_CELL_DEPLOY_KEY" ]; then
  echo "dev-cell-git-ssh-env: no deploy key at $DEV_CELL_DEPLOY_KEY — did dev-cell-bootstrap.service run?" >&2
  return 1
fi

if [ -s "$DEV_CELL_KNOWN_HOSTS" ]; then
  DEV_CELL_SSH_STRICT=yes
elif [ "${DEV_CELL_ALLOW_TOFU:-0}" = "1" ]; then
  echo "dev-cell-git-ssh-env: WARNING known_hosts is empty and DEV_CELL_ALLOW_TOFU=1 — trusting the Gitea host key on first connect (opt-in, MITM risk)" >&2
  DEV_CELL_SSH_STRICT=accept-new
else
  echo "dev-cell-git-ssh-env: known_hosts is empty in the bootstrap bundle — refusing to use SSH over an unverified host (set DEV_CELL_ALLOW_TOFU=1 to explicitly opt into trust-on-first-use)" >&2
  return 1
fi

export GIT_SSH_COMMAND="ssh -i $DEV_CELL_DEPLOY_KEY -o IdentitiesOnly=yes -o UserKnownHostsFile=$DEV_CELL_KNOWN_HOSTS -o StrictHostKeyChecking=$DEV_CELL_SSH_STRICT -o BatchMode=yes"
unset DEV_CELL_SSH_STRICT
