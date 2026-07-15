# frozen_string_literal: true

require "rails_helper"

# Campaign 019f6084 inc1 — base-os closure guarantee.
#
# base-os-ubuntu-noble now `provides: os.userland`, and every ELF-shipping
# platform module (claude-tmux, dev-cell, gitea-act-runner, module-forge,
# postgres-primary, postgres-replica, redis, qemu-guest-agent, runtime-ruby,
# node-exporter, storage-tools, runtime-node) declares
# `requires: capability:os.userland`. base-os itself, powernode-system-base,
# powernode-hub-frontend (dist/ only, no ELF), reverse-proxy-traefik (static
# Go binary), powernode-extension-system, and log-forwarder-vector are
# deliberately untouched — see modules/*/manifest.yaml for the per-module
# rationale comment landed alongside this spec.
#
# This proves the closure guarantee end to end by driving the REAL
# production seed path — powernode_platform_modules.rb, which loads every
# on-disk manifest via System::PlatformModuleManifestLoader and imports it
# through the REAL System::ManifestImportService (the same capability-
# resolution code every CI publish exercises), then powernode_platform_
# templates.rb, which builds the platform's 7 real NodeTemplates — and the
# REAL apply path, System::TemplateApplyService (wrapping
# System::TemplateExpansionService / System::DependencyResolutionService).
# No synthetic/factory-only graph stands in for any of this.
#
# Ground truth (verified empirically against the actual module graph, not
# assumed from the plan): base-os-ubuntu-noble resolves into the closure of
# 4 of the 5 cloud_init hub templates (powernode-hub, powernode-hub-api,
# powernode-hub-worker, powernode-hub-cluster-member) — transitively via
# runtime-ruby / postgres-primary / postgres-replica / redis's new requires
# edge. powernode-hub-frontend does NOT gain base-os: its only two modules
# (reverse-proxy-traefik, powernode-hub-frontend) are BOTH deliberately
# excluded from this increment's requires edges (static Go binary /
# dist-only static assets — neither links against base-os's libc), so there
# is no path into the closure. That's intentional, not a gap — this spec
# pins it as a negative assertion so a future edit that adds an unwarranted
# requires edge to either module gets caught. The two pivot templates
# (powernode-physical-smoke, powernode-hub-pivot) already list
# base-os-ubuntu-noble as an explicit TemplateModule; the closure guarantee
# doesn't change their result, but they're included as a same-account
# sanity baseline alongside the cloud_init templates.
#
# --- unrelated pre-existing schema-drift note ---------------------------
# server/db/schema.rb is missing the `unit_body` column AND the relaxed
# `start_command` NOT NULL constraint that migration
# extensions/system/server/db/migrate/20260710090000_add_unit_body_to_
# system_module_services.rb adds (schema.rb's version marker is
# chronologically after that migration but never picked up either ALTER —
# a schema-dump drift, reproduces identically against the manifests BEFORE
# this increment's edits too, so it's unrelated to inc1). On any
# schema:load-built DB (every worktree's isolated test DB) this makes
# System::ManifestImportService#apply_services raise `NoMethodError:
# undefined method 'unit_body='`, then (once worked around)
# `PG::NotNullViolation` on start_command, for EVERY module manifest with a
# non-empty `services:` block — i.e. most of the real catalog, not just the
# modules that use the `unit_body:` passthrough. Confirmed and queued as
# improvement 019f6423-f0b3-7569-a9e0-c431e9353965
# (schema_drift|server/db/schema.rb|system_module_services.unit_body)
# rather than fixed in server/db/schema.rb — regenerating that file is out
# of scope for an add-only manifest increment and has platform-wide blast
# radius. This worktree's OWN isolated test DB (a disposable, per-worktree
# throwaway per scripts/prepare-worktree.sh, not the tracked schema.rb) was
# brought in line with what its own schema_migrations already claims is
# applied by running migration 20260710090000's two DDL statements directly
# against it — no tracked file changed.

RSpec.describe "base-os closure guarantee (campaign 019f6084 inc1)" do
  SEED_DIR = Rails.root.join("..", "extensions", "system", "server", "db", "seeds")

  ELF_SHIPPING_MODULES = %w[
    claude-tmux dev-cell gitea-act-runner module-forge postgres-primary
    postgres-replica redis qemu-guest-agent runtime-ruby node-exporter
    storage-tools runtime-node
  ].freeze

  CLOUD_INIT_TEMPLATES_GAINING_BASE_OS = %w[
    powernode-hub powernode-hub-api powernode-hub-worker powernode-hub-cluster-member
  ].freeze

  PIVOT_TEMPLATES = %w[powernode-physical-smoke powernode-hub-pivot].freeze

  let!(:account) { create(:account) }

  before do
    # `load` (not `require`) re-executes each seed's top-level constants on
    # every example — silence_warnings matches the existing convention in
    # spec/seeds/system_agents_persona_and_tier_spec.rb.
    silence_warnings do
      load SEED_DIR.join("powernode_platform_categories.rb")
      load SEED_DIR.join("powernode_platform_modules.rb")
      load SEED_DIR.join("powernode_platform_templates.rb")
    end
  end

  let(:base_os_module) { System::NodeModule.find_by!(account: account, name: "base-os-ubuntu-noble") }

  def closure_names_for(template_name)
    template = System::NodeTemplate.find_by!(account: account, name: template_name)
    node = create(:system_node, account: account, node_template: template)
    result = System::TemplateApplyService.new(node).apply!(dry_run: true)
    expect(result.errors).to eq([]), "#{template_name} apply errors: #{result.errors.join('; ')}"
    result.created.map { |c| c.node_module.name }
  end

  describe "capability resolution" do
    it "resolves capability:os.userland from every ELF-shipping module to base-os-ubuntu-noble" do
      ELF_SHIPPING_MODULES.each do |name|
        mod = System::NodeModule.find_by!(account: account, name: name)
        edge = System::ModuleDependency.find_by(
          node_module: mod, dependency: base_os_module, dependency_type: "requires"
        )
        expect(edge).to be_present,
          "#{name} → base-os-ubuntu-noble requires edge missing (capability:os.userland did not resolve)"
      end
    end

    it "base-os-ubuntu-noble itself provides os.userland" do
      expect(base_os_module.capabilities).to include("os.userland")
    end
  end

  describe "no dependency cycle" do
    it "detects no circular dependency across the full platform module graph" do
      available = System::NodeModule.where(account: account).includes(:module_dependencies, :dependencies)
      result = System::DependencyResolutionService.new(available).resolve(available.to_a)
      circular = result.errors.select { |e| e[:type] == :circular_dependency }
      expect(circular).to eq([]), circular.map { |e| e[:message] }.join("; ")
    end

    it "base-os-ubuntu-noble's own transitive requires never loop back through a new os.userland consumer" do
      expect(base_os_module.all_dependencies.map(&:name)).not_to include(*ELF_SHIPPING_MODULES)
    end
  end

  describe "cloud_init hub template closures" do
    CLOUD_INIT_TEMPLATES_GAINING_BASE_OS.each do |template_name|
      it "#{template_name}: resolves base-os-ubuntu-noble into its closure transitively" do
        expect(closure_names_for(template_name)).to include("base-os-ubuntu-noble")
      end
    end

    it "powernode-hub-frontend: does NOT resolve base-os-ubuntu-noble (reverse-proxy-traefik + " \
       "hub-frontend are both excluded from inc1's requires edges)" do
      expect(closure_names_for("powernode-hub-frontend")).not_to include("base-os-ubuntu-noble")
    end
  end

  describe "pivot template baseline (unaffected — base-os already explicit)" do
    PIVOT_TEMPLATES.each do |template_name|
      it "#{template_name}: base-os-ubuntu-noble is present as an explicit TemplateModule" do
        template = System::NodeTemplate.find_by!(account: account, name: template_name)
        names = template.template_modules.includes(:node_module).map { |tm| tm.node_module.name }
        expect(names).to include("base-os-ubuntu-noble")
      end
    end
  end
end
