# Powernode dev cell

Your persistent dev box. Home (`~`) is backed by /persist, so it survives
reboots/recompose — Claude Code auth (`~/.claude`), cloned source, `~/.ssh`, and
shell history all persist.

## Get started
    cd ~/work                                  # powernode-platform (system ext at extensions/system)
    cd ~/work/server && bin/rails db:migrate   # dev DB (powernode_development) is already created
    tmux                                       # persistent terminal
    claude                                     # Claude Code — first run prompts for auth (your account)

## Good to know
- **Source workspace** `~/work`: powernode-platform at the root, powernode-system
  at `~/work/extensions/system`. If it didn't auto-clone, run `dev-cell-clone`.
- **Git deploy key**: generated ON this box; the PUBLIC key is auto-registered with
  Gitea (the private key never leaves here). Revoke it in Gitea → Settings → SSH Keys.
- **Frontend**: `cd ~/work/frontend && npm run dev`.
- **SSH identity** is persisted, so reconnecting won't trip host-key warnings.
