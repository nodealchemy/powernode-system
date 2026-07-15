# Module erofs Size Ledger — Phase 0 Baseline

> Status: baseline (campaign 019f6084 inc0, collected 2026-07-14)

Per-module, per-architecture erofs artifact size, sourced **read-only** from
the platform DB (`System::ModuleArtifact.size_bytes`, latest artifact per
module/arch). This is the "before" snapshot the file_spec-conformance work
in later increments of this campaign diffs against — once modules 1-for-1
correct their `file_spec` (per `derive-file-spec.sh conformance`, see
[scripts/module-build/derive-file-spec.sh](../scripts/module-build/derive-file-spec.sh)),
re-running the same query should show shrinking blobs for any module that
was over-including.

## Collection method (repeatable)

Read-only against the platform's Rails models — no build, no writes, no
migrations. Restricted to the modules actually tracked in this repo's
`modules/` directory (the DB also carries seed/example/test `NodeModule`
rows with no corresponding manifest — see "Scope" below).

```bash
cd server
RAILS_ENV=development bin/rails runner '
  tracked = Dir.glob("/absolute/path/to/extensions/system/modules/*/manifest.yaml")
              .map { |p| File.basename(File.dirname(p)) }.sort

  System::NodeModule.where(name: tracked).order(:name).each do |mod|
    System::ModuleArtifact::SUPPORTED_ARCHITECTURES.each do |arch|
      artifact = System::ModuleArtifact.joins(:node_module_version)
        .where(architecture: arch,
               system_node_module_versions: { node_module_id: mod.id })
        .order(built_at: :desc)
        .first
      next unless artifact
      puts [mod.name, arch, artifact.size_bytes, artifact.built_at,
            artifact.node_module_version.version_number,
            artifact.node_module_version.promotion_state].join("\t")
    end
  end
'
```

"Latest artifact per module/arch" = the `ModuleArtifact` with the most
recent `built_at` among all `NodeModuleVersion`s belonging to that
`NodeModule`, for that `architecture`. `System::ModuleArtifact::SUPPORTED_ARCHITECTURES`
= `amd64`, `arm64` (`server/app/models/system/module_artifact.rb:16`).

## Scope

45 `NodeModule` rows exist in this dev DB; only 20 have a `modules/<slug>/manifest.yaml`
in this repo (the other 25 — `apache`, `chrony`, `nginx`, `rpi4-firmware`,
`security-hardening` from `templates/example-modules/`, plus assorted
dev/test fixtures like `test-orch-b085fa70`, `honeypot-canary`,
`k3s-agent`/`k3s-server`, `sdwan-overlay` — are seed/example/test data with
no git-tracked manifest). This ledger covers only the 20 real,
pipeline-built modules. All 20 have a matching `NodeModule` row (no
orphans in either direction).

## Ledger (20 tracked modules)

| Module | amd64 | arm64 | Built at | Version | Promotion state |
|---|---|---|---|---|---|
| base-os-ubuntu-noble | not yet built | not yet built | — | — | — |
| claude-tmux | not yet built | not yet built | — | — | — |
| dev-cell | not yet built | not yet built | — | — | — |
| gitea-act-runner | not yet built | not yet built | — | — | — |
| log-forwarder-vector | not yet built | not yet built | — | — | — |
| module-forge | not yet built | not yet built | — | — | — |
| **node-exporter** | 12,345,000 B (11.77 MiB) | 12,345,001 B (11.77 MiB) | 2026-07-14T10:23:44Z | 12 | built |
| postgres-primary | not yet built | not yet built | — | — | — |
| postgres-replica | not yet built | not yet built | — | — | — |
| powernode-extension-system | not yet built | not yet built | — | — | — |
| powernode-hub-backend | not yet built | not yet built | — | — | — |
| powernode-hub-frontend | not yet built | not yet built | — | — | — |
| powernode-hub-worker | not yet built | not yet built | — | — | — |
| powernode-system-base | not yet built | not yet built | — | — | — |
| qemu-guest-agent | not yet built | not yet built | — | — | — |
| redis | not yet built | not yet built | — | — | — |
| reverse-proxy-traefik | not yet built | not yet built | — | — | — |
| runtime-node | not yet built | not yet built | — | — | — |
| runtime-ruby | not yet built | not yet built | — | — | — |
| storage-tools | not yet built | not yet built | — | — | — |

## Findings (grounded in the query above, run 2026-07-14 against /opt/powernode's dev DB)

- **19 of 20 tracked modules have never been built** in this dev
  environment — this platform instance has never run
  `build-platform-modules.yaml` end to end (or the CI worker that would
  notify `POST /api/v1/system/module_publications` has never fired for
  them). There is no size baseline for `base-os-ubuntu-noble` itself yet,
  which is the module the base-os hygiene masks in this same increment
  touch.
- **node-exporter's one artifact row looks like seed/fixture data, not a
  real CI build**: both architectures report suspiciously round,
  sequential values (`size_bytes` 12345000 / 12345001, `oci_digest`
  ending `...780000` / `...780001`, identical `built_at` to the
  millisecond). Treat this row as **not a trustworthy production
  baseline** — it's almost certainly `db:seed` data, not a genuine
  mmdebstrap/erofs build. Re-run the collection query after the first
  real CI build lands to get a trustworthy number.
- Net: this campaign currently has **no real "before" erofs size data** to
  diff against. The value of this doc for now is the repeatable query
  itself — re-run it after Phase 2+'s corrected `file_spec`s actually
  build, and again on `develop`'s next real CI run of
  `base-os-ubuntu-noble`, to get the first trustworthy baseline.
