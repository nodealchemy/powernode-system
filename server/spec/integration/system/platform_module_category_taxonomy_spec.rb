# frozen_string_literal: true

require "rails_helper"

# Campaign 019f6084 — module category taxonomy + capability-resolution-order
# fix.
#
# Before this increment, every one of the platform's 20 modules was seeded
# into a SINGLE "Powernode Platform" category (position 500). That tied
# every module's NodeModule#effective_priority (category.position *
# PRIORITY_CATEGORY_MULTIPLIER + module.priority) to the same value, so the
# overlay union's layer order (System::NodeModule.by_priority — highest
# effective_priority mounts LAST, closest to root) was tie-broken by name,
# not by any deliberate layering intent: an operator had no way to reason
# about which module's files "win" when two modules both ship the same
# path, because nothing in the platform actually decided that.
#
# This spec drives the REAL production seed path — powernode_platform_
# categories.rb (creates the System::NodeModuleCategory::PLATFORM_TAXONOMY
# triplets + retires the legacy catch-all) and powernode_platform_modules.rb
# (imports every on-disk manifest via the REAL System::ManifestImportService,
# the same capability-resolution code every CI publish exercises) — on a
# SINGLE fresh account, in ONE seed run, the way an operator would actually
# experience it. No synthetic/factory-only graph stands in for any of this.
#
# It also proves the folded-in capability-resolution-order fix: powernode_
# platform_modules.rb imports all 20 manifests in a single ALPHABETICAL
# pass, so a `requires: capability:<tag>` only resolves into a
# ModuleDependency edge if the PROVIDING module already exists (with its
# `capabilities` populated) at the moment the CONSUMING module imports.
# claude-tmux ("c...") requires capability:runtime.node, provided by
# runtime-node ("r..."), which sorts and therefore imports AFTER it — so on
# a naive single pass the edge silently defers (ManifestImportService logs
# "not yet known on platform; deferring" and reports status: "unresolved").
# inc1's `capability:os.userland` edges happened to resolve on a single pass
# only because base-os-ubuntu-noble ("b...") sorts first alphabetically —
# every one of its consumers sorts after it by coincidence, not by design.
# The fix adds a second full re-resolution pass, after every manifest in the
# batch has been imported once, so forward-reference import order no longer
# matters.
RSpec.describe "platform module category taxonomy + capability-order fix (campaign 019f6084)" do
  SEED_DIR = Rails.root.join("..", "extensions", "system", "server", "db", "seeds")

  # Mirrors the taxonomy table from the campaign brief / PLATFORM_TAXONOMY,
  # keyed by module name -> the category's display base_name.
  EXPECTED_CATEGORY_BY_MODULE = {
    "powernode-system-base"      => "System Base",
    "base-os-ubuntu-noble"       => "Base OS",
    "runtime-node"               => "Language Runtime",
    "runtime-ruby"               => "Language Runtime",
    "postgres-primary"           => "Data Plane",
    "postgres-replica"           => "Data Plane",
    "redis"                      => "Data Plane",
    "storage-tools"              => "Storage & Guest",
    "qemu-guest-agent"           => "Storage & Guest",
    "reverse-proxy-traefik"      => "Networking / Proxy",
    "node-exporter"              => "Observability",
    "log-forwarder-vector"       => "Observability",
    "gitea-act-runner"           => "Build & Dev",
    "module-forge"               => "Build & Dev",
    "dev-cell"                   => "Build & Dev",
    "claude-tmux"                => "Build & Dev",
    "powernode-hub-backend"      => "Platform Apps",
    "powernode-hub-worker"       => "Platform Apps",
    "powernode-hub-frontend"     => "Platform Apps",
    "powernode-extension-system" => "Platform Apps"
  }.freeze

  let!(:account) { create(:account) }

  before do
    # `load` (not `require`) re-executes each seed's top-level constants on
    # every example — matches base_os_closure_guarantee_spec.rb's convention.
    silence_warnings do
      load SEED_DIR.join("powernode_platform_categories.rb")
      load SEED_DIR.join("powernode_platform_modules.rb")
    end
  end

  describe "manifest-driven category assignment" do
    EXPECTED_CATEGORY_BY_MODULE.each do |module_name, category_name|
      it "#{module_name} -> '#{category_name}'" do
        mod = System::NodeModule.find_by!(account: account, name: module_name)
        expect(mod.category&.name).to eq(category_name)
      end
    end

    it "every platform module lands in a real category (none nil / uncategorized)" do
      mods = System::NodeModule.where(account: account, name: EXPECTED_CATEGORY_BY_MODULE.keys)
      expect(mods.count).to eq(EXPECTED_CATEGORY_BY_MODULE.size)
      expect(mods.pluck(:category_id)).to all(be_present)
    end

    it "each assigned category is subscription-variety and part of a wired triplet" do
      base_os = System::NodeModule.find_by!(account: account, name: "base-os-ubuntu-noble")
      cat = base_os.category
      expect(cat.variety).to eq("subscription")
      expect(cat.config_category).to be_present
      expect(cat.instance_category).to be_present
    end
  end

  describe "legacy 'Powernode Platform' catch-all retirement" do
    it "does not exist after the seed runs" do
      expect(
        System::NodeModuleCategory.find_by(account: account, name: "Powernode Platform")
      ).to be_nil
    end

    it "no platform module still points at a stale pre-taxonomy category" do
      taxonomy_names = System::NodeModuleCategory::PLATFORM_TAXONOMY.values.map { |v| v[:base_name] }
      mods = System::NodeModule.where(account: account, name: EXPECTED_CATEGORY_BY_MODULE.keys).includes(:category)
      mods.each do |mod|
        expect(taxonomy_names).to include(mod.category.name)
      end
    end

    # The outer `before` seeds a brand-new account, which never had the
    # legacy category to begin with — that only proves the seed doesn't
    # RECREATE it. This exercises the actual retirement branch: an account
    # that already has the pre-campaign single-category state (simulating
    # /opt/powernode's real history) gets it destroyed on the next seed run,
    # and any module still pointing at it (including a hypothetical
    # operator-authored one, not just the 20 platform modules) is nullified
    # rather than orphaned.
    it "destroys a pre-existing legacy triplet and nullifies (not orphans) any module still pointing at it" do
      retirement_account = create(:account)
      legacy = System::NodeModuleCategory.create_triplet!(
        account: retirement_account, base_name: "Powernode Platform", base_position: 500
      )
      stray = create(:system_node_module, account: retirement_account, category: legacy, variety: "subscription")

      silence_warnings { load SEED_DIR.join("powernode_platform_categories.rb") }

      expect(
        System::NodeModuleCategory.where(account: retirement_account,
                                          name: [ "Powernode Platform", "Powernode Platform (config)",
                                                   "Powernode Platform (instance)" ])
      ).to be_empty
      expect(stray.reload.category_id).to be_nil
    end
  end

  describe "effective_priority differentiation (deterministic overlay order)" do
    it "base-os < language-runtime < data-plane < platform-apps" do
      base_os  = System::NodeModule.find_by!(account: account, name: "base-os-ubuntu-noble")
      runtime  = System::NodeModule.find_by!(account: account, name: "runtime-ruby")
      data     = System::NodeModule.find_by!(account: account, name: "postgres-primary")
      app      = System::NodeModule.find_by!(account: account, name: "powernode-hub-backend")

      expect(base_os.effective_priority).to be < runtime.effective_priority
      expect(runtime.effective_priority).to be < data.effective_priority
      expect(data.effective_priority).to be < app.effective_priority
    end

    it "system-base sorts below base-os, which sorts below every other tier" do
      system_base = System::NodeModule.find_by!(account: account, name: "powernode-system-base")
      base_os     = System::NodeModule.find_by!(account: account, name: "base-os-ubuntu-noble")
      expect(system_base.effective_priority).to be < base_os.effective_priority
    end
  end

  describe "capability-resolution-order fix (two-pass sweep)" do
    it "resolves claude-tmux's capability:runtime.node edge to runtime-node on a SINGLE fresh seed run" do
      claude_tmux  = System::NodeModule.find_by!(account: account, name: "claude-tmux")
      runtime_node = System::NodeModule.find_by!(account: account, name: "runtime-node")

      edge = System::ModuleDependency.find_by(
        node_module: claude_tmux, dependency: runtime_node, dependency_type: "requires"
      )
      expect(edge).to be_present,
        "claude-tmux -> runtime-node requires edge missing (capability:runtime.node did not resolve)"
    end

    it "resolves claude-tmux's capability:os.userland edge to base-os-ubuntu-noble alongside the new edge" do
      claude_tmux = System::NodeModule.find_by!(account: account, name: "claude-tmux")
      base_os     = System::NodeModule.find_by!(account: account, name: "base-os-ubuntu-noble")

      edge = System::ModuleDependency.find_by(
        node_module: claude_tmux, dependency: base_os, dependency_type: "requires"
      )
      expect(edge).to be_present
    end

    it "resolves every inc1 os.userland-requiring module's edge to base-os-ubuntu-noble" do
      base_os = System::NodeModule.find_by!(account: account, name: "base-os-ubuntu-noble")
      elf_shipping_modules = %w[
        claude-tmux dev-cell gitea-act-runner module-forge postgres-primary
        postgres-replica redis qemu-guest-agent runtime-ruby node-exporter
        storage-tools runtime-node
      ]

      elf_shipping_modules.each do |name|
        mod = System::NodeModule.find_by!(account: account, name: name)
        edge = System::ModuleDependency.find_by(
          node_module: mod, dependency: base_os, dependency_type: "requires"
        )
        expect(edge).to be_present, "#{name} -> base-os-ubuntu-noble requires edge missing"
      end
    end
  end
end
