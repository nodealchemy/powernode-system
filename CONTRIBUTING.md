# Contributing to the Powernode System Extension

Thanks for your interest in improving this extension. This guide covers
the development workflow, including the slightly-tricky submodule layout
that exists because this extension is consumed by the parent
[Powernode platform](https://github.com/nodealchemy/powernode-platform).

## Submodule context

This repo is mounted into `powernode-platform` at `extensions/system/`. Most
real-world testing requires the parent platform running so the Rails
autoloader sees the extension's namespaces (`System::*`, `Api::V1::System::*`).

```
powernode-platform/                  ← parent (separate repo)
├── server/                          ← parent's Rails app
├── frontend/                        ← parent's React app
├── extensions/
│   └── system/                      ← THIS repo (submodule)
│       ├── server/                  ← extension's Rails models / services
│       ├── frontend/                ← extension's React components
│       ├── worker/                  ← extension's Sidekiq jobs
│       └── ...
```

## Setting up locally

```bash
# Clone the parent platform with submodules
git clone --recurse-submodules https://github.com/nodealchemy/powernode-platform.git
cd powernode-platform

# Or if already cloned without submodules:
git submodule update --init --recursive

# Set up the extension's dev branch in the submodule
cd extensions/system
git checkout master         # or develop, if you have a branch strategy
git remote -v               # verify origin (Gitea) + github
```

## Running the extension's tests

From the parent platform's `server/` directory (so the autoloader sees
the parent's app code):

```bash
# Backend rspec
cd /path/to/powernode-platform/server
bundle exec rspec ../extensions/system/server/spec/

# Frontend type-check
cd ../extensions/system/frontend
# (or use the platform's tsconfig.check.json if you've created one)
npx tsc --noEmit

# Go agent
cd ../agent
go test ./...
```

## Committing

This is the part that bites everyone the first time:

1. **Always commit inside `extensions/system/` first.** From the parent
   platform's perspective, your changes look like a submodule pointer change
   until you've committed inside the submodule.

   ```bash
   cd extensions/system
   git checkout -b my-feature
   # ... make changes ...
   git add server/...
   git commit -m "feat: add foo"
   git push origin my-feature
   ```

2. **Then update the parent's submodule pointer:**

   ```bash
   cd ..    # back to parent platform root
   git add extensions/system
   git commit -m "Bump system extension to <sha>"
   ```

3. **Open a PR** in this repo (the system extension), and a separate PR in
   the parent platform pointing at your new SHA.

## Code style

| Layer | Rule |
|---|---|
| Ruby | `# frozen_string_literal: true` pragma, `Rails.logger` (no `puts`) |
| TypeScript | No `any`, no `console.log` in production code, theme classes only (`bg-theme-*`) |
| Go | `gofmt`, prefer the `internal/` layout for non-public packages |
| YAML | 2-space indent, no tabs |
| Migrations | Use `t.references` with built-in indexes; never `add_index` for FKs separately |

## Permission-based access control

**This is non-negotiable in the platform's frontend:** check permissions, never roles.

```typescript
// ✅ correct
currentUser?.permissions?.includes('system.modules.update')

// ❌ wrong — frontend doesn't see role objects
currentUser?.roles?.includes('admin')
```

Backend uses `current_user.has_permission?('name')`.

## Test requirements

- All new services + controllers need rspec coverage
- Frontend specs use Vitest + React Testing Library
- E2E flows go in `frontend/cypress/e2e/` (parent platform's cypress)

## Submitting a PR

PRs that touch FleetAutonomyService, the AI Skill executors, or anything in
`server/db/migrate/` get extra scrutiny:

- Migrations must be reversible (provide `down`)
- New autonomy actions need: `ACTION_PERMISSIONS` entry, intervention policy
  default, dedup_key_for case, ADVANCEMENT_ACTIONS membership decision
- New AI skills need a descriptor + a spec covering plan-vs-execute split

## Reporting issues

For bugs in the extension itself: open issues here on GitHub. For bugs in
the parent platform's integration with this extension: open in
[powernode-platform](https://github.com/nodealchemy/powernode-platform).

## License

By contributing, you agree your contributions are licensed under
MIT (see [LICENSE](./LICENSE)).
