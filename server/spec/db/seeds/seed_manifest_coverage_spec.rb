# frozen_string_literal: true

require "rails_helper"
require "prism"

# IMP-1634d69fafc8 — a seeded NodeModule that is catalog-advertised but has no
# `extensions/system/modules/<name>/` manifest directory is invisible to
# System::ModuleBuildPlannerService (it excludes such a row as `no_manifest`),
# so it can never be built or published while still appearing assignable.
#
# Two INDEPENDENT assertions, because "seeded" is ambiguous and the two
# readings have opposite blind spots:
#
#   (i)  MANIFEST COVERAGE — over the seed files that ACTUALLY RUN (derived
#        from SYSTEM_SEED_FILES in the orchestrator, never hardcoded here).
#        A module only becomes catalog-advertised if its seed runs.
#
#   (ii) ORPHANED SEEDS — any db/seeds/*.rb that is neither listed in
#        SYSTEM_SEED_FILES nor covered by a mechanically-derived exemption is
#        dead code and must be named. Scanning every *.rb for (i) instead
#        would assert over smoke_test_*/example_* files that deliberately
#        never run; naming them here keeps (i) honest and still refuses to let
#        a never-run seed sit silently.
#
# KNOWN, DELIBERATE BLIND SPOT of (i): `node_module_catalog.rb` (which DOES
# run) delegates its catalog body to
# System::AccountBootstrapService.seed_templates_for, which creates six
# further NodeModules (system-base, security-hardening, chrony, apache,
# nginx, rpi4-firmware) in Ruby the scanner never reads. Those are
# `public: false` (the column default — the service never sets it), so they
# are not catalog-advertised and out of this guard's stated scope. The
# creation-site pin below goes red if a running seed ever starts creating
# modules somewhere the scanner has not been taught about.
module SeedManifestCoverage
  SEEDS_PATH        = Rails.root.join("../extensions/system/server/db/seeds").cleanpath.freeze
  ORCHESTRATOR_PATH = Rails.root.join("../extensions/system/server/db/seeds.rb").cleanpath.freeze
  MODULES_PATH      = Rails.root.join("../extensions/system/modules").cleanpath.freeze

  # Exclusion PATTERNS the orchestrator documents in its own header. Their
  # presence in the orchestrator source is asserted below, so a change of
  # exclusion policy there fails loudly here instead of silently degrading.
  DOCUMENTED_PATTERNS = {
    "smoke_test_*" => /\Asmoke_test_/,
    "example_*"    => /\Aexample_/
  }.freeze

  # ── Allow-list for assertion (i) ────────────────────────────────────────
  # A seeded module that is deliberately catalog-only: advertised for
  # composition but never built as an overlay artifact, so it legitimately has
  # no modules/<name>/ tree. Every entry must still be produced by the scan
  # and must still lack a manifest dir, or the staleness example fails.
  CATALOG_ONLY_MODULES = {
    "nodejs-runtime"  => "role_modules_seed.rb — PlanComposer (Slice C) role module. Materialized from " \
                         "package_spec/config[\"manifest\"][\"init_script\"] (apt + NodeSource) at compose " \
                         "time, never from an overlay artifact, so it has no modules/<name>/ build inputs.",
    "python-runtime"  => "role_modules_seed.rb — PlanComposer role module; apt-materialized, see nodejs-runtime.",
    "postgres-server" => "role_modules_seed.rb — PlanComposer role module; apt-materialized. Distinct from the " \
                         "built `postgres-primary`/`postgres-replica` platform modules.",
    "redis-cache"     => "role_modules_seed.rb — PlanComposer role module; apt-materialized. Distinct from the " \
                         "built `redis` platform module.",
    "docker-runtime"  => "role_modules_seed.rb — PlanComposer role module; apt-materialized (get.docker.com). " \
                         "Distinct from the built `dev-cell-docker` platform module."
  }.freeze

  # ── Allow-list for assertion (ii) ───────────────────────────────────────
  # A db/seeds/*.rb that never runs on `rails db:seed` and is not exempted by
  # any derived rule. Every entry must still exist and still be orphaned, or
  # the staleness example fails.
  ORPHANED_SEEDS = {
    "gpu_nvidia_runtime_module.rb" =>
      "OPEN QUESTION — IMP-1634d69fafc8. Creates a subscription/enabled/public `gpu-nvidia-runtime` " \
      "NodeModule with no modules/gpu-nvidia-runtime/ tree (the seed's own header admits it). Because it " \
      "is not in SYSTEM_SEED_FILES it never runs, so no such row exists on any install — the offer's " \
      "premise that it is catalog-advertised is FALSE, and editing the row's flags would be an inert " \
      "no-op. Listed here so the orphan stays visible rather than silent; the disposition (author the " \
      "manifest and list the seed, or delete the seed) is the operator's call.",
    "inference_runtime_module.rb" =>
      "Same family as gpu_nvidia_runtime_module.rb (AI/MCP workload substrate L1) and requires it. Never " \
      "runs, so its ollama module row never exists. Shares that offer's disposition.",
    "powernode_platform_modules.rb" =>
      "Operator/deploy-time platform bootstrapper: imports every extensions/system/modules/<name>/ " \
      "manifest from disk via System::PlatformModuleManifestLoader. Self-documented 'Invoke explicitly: " \
      "rails runner load ...'. Deliberately not part of db:seed (it needs the modules tree on disk), but " \
      "the orchestrator never says so.",
    "powernode_platform_categories.rb" =>
      "Prerequisite of powernode_platform_modules.rb (must run first). Same operator-run bootstrapper " \
      "class; loaded directly by integration specs.",
    "powernode_platform_templates.rb" =>
      "Runs after powernode_platform_modules.rb to compose the platform templates. Same operator-run " \
      "bootstrapper class.",
    "powernode_dev_cell.rb" =>
      "Operator-run dev-cell topology bootstrapper (template + paused InstancePool + isolated " \
      "Sdwan::Network). Depends on powernode_platform_modules.rb having run first.",
    "cutover_renamed_modules.rb" =>
      "One-off cutover script for the 2026-05-24 module-rename pass; destructive (deletes stale " \
      "NodeModule rows) and re-loads the two platform bootstrappers. Correctly never part of db:seed.",
    "sdwan_flow_exporter_module.rb" =>
      "Operator-run module catalog seed (IMP-5a018031cc29). Sdwan::FlowExporterDeployer's error path " \
      "instructs the operator to run it explicitly, then build and publish the module.",
    "federation_contract_v1.rb" =>
      "Seeds the Social Contract v1 FederationContractVersion row. Federation is built but unused (zero " \
      "partners/peers/grants), so the row has no consumer; never listed."
  }.freeze

  # ── Declaration for assertion (iii) ─────────────────────────────────────
  #
  # Verbatim from db/seeds/gpu_nvidia_runtime_module.rb:76-79 — the seed's own
  # description, LIFTED rather than restated. It is accurate and considered,
  # and a paraphrase would have softened it; the example below pins it as a
  # substring of the seed's actual bytes so the two cannot drift apart. Its
  # "below" refers to the sharing-model paragraph in the SEED, not to anything
  # in this file — that is what quoting rather than re-authoring costs.
  GPU_NVIDIA_RUNTIME_LIFTED = <<~PROSE.strip
    NOT YET IMPLEMENTED: registering an "nvidia" container runtime with dockerd.
    No agent code does this, and there is no `modules/gpu-nvidia-runtime/`
    artifact behind this row; assigning it today installs the package set and
    nothing more. Do not read the sharing model below as a working capability.
  PROSE

  # ADVERTISED BUT NOT BUILDABLE. Each key is a module an operator-invocable
  # seed creates as a catalog row with no `extensions/system/modules/<name>/`
  # tree behind it, so System::ModuleBuildPlannerService excludes it as
  # `no_manifest` and it can never be built or published — while an operator
  # can still assign it.
  #
  # This is a DECLARATION of a known gap, not an exemption that makes it fine.
  # The equality below deletes an entry the moment its manifest lands.
  UNBUILDABLE_OPERATOR_MODULES = {
    "gpu-nvidia-runtime" => GPU_NVIDIA_RUNTIME_LIFTED,

    "inference-ollama" =>
      "inference_runtime_module.rb — same AI/MCP workload-substrate family, and it requires " \
      "gpu-nvidia-runtime on the same node (that seed's header, :14). No modules/inference-ollama/ " \
      "tree exists, so the ollama runtime is catalog-only for the same reason its prerequisite is. " \
      "System::InferenceDeploymentService#find_module! raises 'run its seed first' for both, which " \
      "is what makes the pair reachable from system_deploy_inference_server.",

    "docker-engine" =>
      "docker_runtime_module.rb — the Docker Engine binary stack (docker-ce, containerd, buildx, " \
      "compose). Its header (:7-8) models it on the `sdwan-overlay` precedent, and sdwan-overlay DOES " \
      "have modules/sdwan-overlay/; this one does not. The seed makes no claim about the missing " \
      "artifact, so unlike gpu-nvidia-runtime there is no authored statement to lift: the artifact is " \
      "simply unauthored. OPEN QUESTION for the operator — author modules/docker-engine/, or say why " \
      "the row is catalog-only.",

    "docker-engine-config" =>
      "docker_runtime_module.rb — the config-variety companion the same header (:8-11) says carries " \
      "runtime config (/etc/docker/daemon.json, TLS material, listen address) per instance. Same " \
      "missing artifact, same open question, same seed.",

    "k3s-server" =>
      "k3s_modules.rb — K3s control plane (kube-apiserver, controller-manager, scheduler, SQLite " \
      "datastore via kine). Its " \
      "header (:6-8) says it mirrors docker_runtime_module.rb / sdwan_overlay_module.rb and ships the " \
      "package install layer only. No modules/k3s-server/ tree. Same open question as docker-engine.",

    "k3s-agent" =>
      "k3s_modules.rb — K3s worker (kubelet, containerd, CNI). No modules/k3s-agent/ tree. Same seed, " \
      "same open question as k3s-server.",

    "sdwan-flow-exporter" =>
      "sdwan_flow_exporter_module.rb — DECLARED PENDING by its own seed, not merely unauthored: the " \
      "header's OPERATOR: BUILD + PUBLISH block (:51-65) states 'This seed lands the definition only' (:53) " \
      "and makes authoring the module source (vector.toml + manifest.yaml) step 2 of a four-step " \
      "operator procedure, deliberately separate because publishing AUTO-PROMOTES fleet-wide. So the " \
      "missing tree here is the documented state between step 1 and step 2, not an oversight."
  }.freeze

  # Creation sites the scanner cannot resolve, each with why it is safe to
  # leave unresolved. An entry is a declared BLIND SPOT in the advertised set,
  # so it needs a reason the gap cannot hide behind it.
  UNRESOLVED_MODULE_CREATION_SITES = {
    "powernode_platform_modules.rb" =>
      "Not a catalog seed but the platform-module LOADER: it iterates " \
      "PLATFORM_MODULE_MANIFESTS_TO_SEED, read off POWERNODE_PLATFORM_MODULES_DISK_ROOT by " \
      "System::PlatformModuleManifestLoader (:67, :69), so the name is a block parameter (:81, creation " \
      "site :82-85) the " \
      "scanner cannot see. Nothing is hidden by that: every module it creates comes FROM a " \
      "modules/<name>/ manifest on disk, so by construction it can never contribute to the gap " \
      "above. It also sets `public = false` (:93), which keeps its rows out of the catalog-advertised " \
      "reading entirely."
  }.freeze

  module_function

  def orchestrator_source
    @orchestrator_source ||= File.read(ORCHESTRATOR_PATH)
  end

  # The %w[] literal the orchestrator loads, parsed rather than re-listed.
  def listed_seed_files
    @listed_seed_files ||= begin
      body = orchestrator_source[/SYSTEM_SEED_FILES\s*=\s*%w\[(.*?)\]/m, 1]
      raise "could not parse SYSTEM_SEED_FILES out of #{ORCHESTRATOR_PATH}" if body.nil?

      body.split(/\s+/).reject(&:empty?)
    end
  end

  def seed_basenames
    @seed_basenames ||= Dir.children(SEEDS_PATH).select { |f| f.end_with?(".rb") }.sort
  end

  def manifest_dirs
    @manifest_dirs ||= Dir.children(MODULES_PATH).select { |d| File.directory?(File.join(MODULES_PATH, d)) }.to_set
  end

  # basename => basenames it pulls in via require_relative / an absolute load
  # of another seed. Lets a helper partial inherit its caller's exemption.
  def seed_references
    @seed_references ||= seed_basenames.to_h do |file|
      src = File.read(File.join(SEEDS_PATH, file))
      refs = src.scan(/require_relative\s+["']([^"']+)["']/).flatten.map { |r| r.end_with?(".rb") ? r : "#{r}.rb" }
      refs += src.scan(%r{db/seeds/([a-z0-9_]+\.rb)}).flatten
      [ file, refs.uniq ]
    end
  end

  # Exempt WITHOUT needing an allow-list entry, by rules derived from the
  # orchestrator itself:
  #   1. listed in SYSTEM_SEED_FILES
  #   2. matches a pattern the orchestrator documents as excluded
  #   3. its basename is named in the orchestrator source (a documented,
  #      deliberate one-off — this is how the four named bootstrappers are
  #      exempted without restating them here)
  def derived_exempt_seeds
    @derived_exempt_seeds ||= begin
      exempt = seed_basenames.select do |file|
        listed_seed_files.include?(file) ||
          DOCUMENTED_PATTERNS.any? { |_label, rx| file.match?(rx) } ||
          orchestrator_source.include?(File.basename(file, ".rb"))
      end.to_set

      #   4. a partial/helper pulled in by a file that is itself exempt under
      #      1-3. Requiring the referrer to be exempt stops two orphans from
      #      exempting each other.
      exempt | seed_basenames.select { |file|
        exempt.any? { |referrer| seed_references[referrer].include?(file) }
      }
    end
  end

  def orphaned_seeds
    seed_basenames - derived_exempt_seeds.to_a
  end

  # ── Static extraction of seeded module names ────────────────────────────
  #
  # A text scan, not an execution: these seeds create rows, hit FKs and expect
  # an Account. Names reach System::NodeModule both as literals and through a
  # spec-array/`each` indirection (role_modules_seed.rb), so the scanner
  # resolves that one idiom explicitly and reports anything else as
  # UNRESOLVED rather than silently extracting nothing.
  class ModuleNameScanner
    CREATION_METHODS = %i[
      find_or_initialize_by find_or_create_by find_or_create_by! create create! new
    ].freeze

    Result = Struct.new(:names, :unresolved, :creation_sites, keyword_init: true)

    def initialize(source)
      @root    = Prism.parse(source).value
      @arrays  = {}
      @strings = {}
      collect_local_assignments(@root)
    end

    def scan
      names = []
      unresolved = []
      sites = 0

      walk(@root, nil) do |call, each_receiver|
        sites += 1
        resolved = resolve(name_argument(call), each_receiver)
        if resolved
          names.concat(Array(resolved))
        else
          unresolved << call.slice.lines.first.strip
        end
      end

      Result.new(names: names.uniq.sort, unresolved: unresolved, creation_sites: sites)
    end

    private

    def walk(node, each_receiver, &blk)
      return unless node.is_a?(Prism::Node)

      yield(node, each_receiver) if node.is_a?(Prism::CallNode) && creation_call?(node)

      child_receiver = each_receiver
      if node.is_a?(Prism::CallNode) && node.block && node.receiver.is_a?(Prism::LocalVariableReadNode)
        child_receiver = node.receiver.name
      end

      node.compact_child_nodes.each { |child| walk(child, child_receiver, &blk) }
    end

    # System::NodeModule / ::System::NodeModule only — NodeModuleCategory and
    # NodeModuleVersion are different tables and must not be scanned in.
    def creation_call?(node)
      return false unless CREATION_METHODS.include?(node.name)

      receiver = node.receiver
      return false unless receiver.is_a?(Prism::ConstantPathNode) || receiver.is_a?(Prism::ConstantReadNode)

      receiver.slice.split("::").last == "NodeModule"
    end

    def name_argument(call)
      args = call.arguments&.arguments || []
      hash = args.find { |a| a.is_a?(Prism::KeywordHashNode) || a.is_a?(Prism::HashNode) }
      return nil unless hash

      assoc_value(hash, "name")
    end

    def assoc_value(hash_node, key)
      assoc = hash_node.elements.grep(Prism::AssocNode).find do |e|
        e.key.is_a?(Prism::SymbolNode) && e.key.unescaped == key
      end
      assoc&.value
    end

    # Literal, `name: <local>` where the local holds a string literal, or
    # `spec[:name]` inside `<local>.each` whose local is an array of spec
    # hashes. Anything else returns nil (reported as UNRESOLVED).
    #
    # The string-local form is not a convenience: `sdwan_flow_exporter_module.rb`
    # writes `module_name = "sdwan-flow-exporter"` and then passes the local, so
    # without it that seed's module is silently absent from every set derived
    # here — an UNDER-report, which is the failure mode an equality oracle
    # cannot see.
    #
    # LIMITATION, stated because it trades a loud UNRESOLVED for a possible
    # wrong name: @strings is FILE-GLOBAL and last-write-wins, with no scope
    # check. A local reassigned between creation sites, or a block parameter
    # shadowing a same-named outer string assignment, would resolve to the
    # wrong literal instead of reporting UNRESOLVED. Verified absent today —
    # no seed assigns two different strings to one local, and the one real
    # near-miss is cross-file (a `module_name` BLOCK PARAM in
    # powernode_platform_modules.rb:81 vs a `module_name` string in
    # sdwan_flow_exporter_module.rb:125), which a per-file table cannot
    # conflate. The pre-existing @arrays path carries the same class of risk;
    # this widens it rather than introducing it.
    def resolve(value, each_receiver)
      return value.unescaped if value.is_a?(Prism::StringNode)

      if value.is_a?(Prism::LocalVariableReadNode) && @strings.key?(value.name)
        return @strings[value.name]
      end

      if value.is_a?(Prism::CallNode) && value.name == :[] &&
         value.receiver.is_a?(Prism::LocalVariableReadNode) && each_receiver
        list = @arrays[each_receiver]
        return list if list.present?
      end

      nil
    end

    def collect_local_assignments(node)
      return unless node.is_a?(Prism::Node)

      if node.is_a?(Prism::LocalVariableWriteNode)
        array = unwrap_array(node.value)
        if array
          @arrays[node.name] = hash_names(array)
        elsif node.value.is_a?(Prism::StringNode)
          @strings[node.name] = node.value.unescaped
        end
      end

      node.compact_child_nodes.each { |child| collect_local_assignments(child) }
    end

    def unwrap_array(node)
      return node if node.is_a?(Prism::ArrayNode)
      return node.receiver if node.is_a?(Prism::CallNode) && node.name == :freeze && node.receiver.is_a?(Prism::ArrayNode)

      nil
    end

    def hash_names(array_node)
      array_node.elements.grep(Prism::HashNode).filter_map do |hash|
        value = assoc_value(hash, "name")
        value.is_a?(Prism::StringNode) ? value.unescaped : nil
      end
    end
  end

  # basename => Result, for the seed files that actually run.
  def scanned_running_seeds
    @scanned_running_seeds ||= listed_seed_files.to_h do |file|
      path = File.join(SEEDS_PATH, file)
      [ file, File.exist?(path) ? ModuleNameScanner.new(File.read(path)).scan : nil ]
    end.compact
  end

  def seeded_module_names
    scanned_running_seeds.values.flat_map(&:names).uniq.sort
  end

  # ── The OPERATOR-INVOCABLE region (assertion (iii)) ─────────────────────
  #
  # `rails db:seed` never runs these, but an operator legitimately does — and
  # the platform tells them to. System::InferenceDeploymentService#find_module!
  # raises "module '<name>' not in catalog — run its seed first"
  # (app/services/system/inference_deployment_service.rb:101-103), which is an
  # instruction to run exactly one of these files. So "never runs on db:seed"
  # is NOT "never creates a catalog row"; assertion (i) does not reach here.
  #
  # DERIVED from the orchestrator, never listed: everything that is neither in
  # SYSTEM_SEED_FILES nor matched by a pattern the orchestrator documents as a
  # never-run playground (smoke_test_*, example_*). Those two patterns are the
  # only files the orchestrator says must never run at all; everything else it
  # excludes is excluded because it is operator-timed, not because it is dead.
  def operator_invocable_seeds
    @operator_invocable_seeds ||= seed_basenames.reject do |file|
      listed_seed_files.include?(file) ||
        DOCUMENTED_PATTERNS.any? { |_label, rx| file.match?(rx) }
    end
  end

  # basename => Result, for the operator-invocable seeds that create modules.
  def scanned_operator_seeds
    @scanned_operator_seeds ||= operator_invocable_seeds.to_h { |file|
      [ file, ModuleNameScanner.new(File.read(File.join(SEEDS_PATH, file))).scan ]
    }.select { |_file, result| result.creation_sites.positive? }
  end

  # The ADVERTISED side of the equality: every module name an operator-invocable
  # seed creates.
  def operator_advertised_module_names
    scanned_operator_seeds.values.flat_map(&:names).uniq.sort
  end

  # ADVERTISED minus BUILDABLE. Both INPUTS to this set are read off disk — the
  # names by parsing the seed sources, the manifests by `Dir.children` on the
  # modules tree — so neither input restates the other, and neither reads the
  # declaration. The EQUALITY, though, is derived-vs-declared: this method is
  # the derived side and UNBUILDABLE_OPERATOR_MODULES is a hand-written
  # declaration, which is why it must be checked in both directions.
  def unbuildable_operator_modules
    operator_advertised_module_names.reject { |name| manifest_dirs.include?(name) }
  end

  # Creation sites in the operator region whose `name:` the scanner cannot
  # resolve. Each such site is a hole in the advertised set, so it is declared
  # rather than tolerated.
  #
  # Declared per FILE, which on its own would be too coarse: a file already
  # named here could gain a SECOND unresolvable site and neither this set nor
  # the gap would move. #operator_creation_site_counts closes that — it pins
  # the site count per file, so a new creation site reddens whether or not its
  # name resolves.
  def unresolved_operator_sites
    scanned_operator_seeds.reject { |_file, result| result.unresolved.empty? }.keys.sort
  end

  def operator_creation_site_counts
    scanned_operator_seeds.transform_values(&:creation_sites).sort.to_h
  end
end

RSpec.describe "seeded node-module manifest coverage (IMP-1634d69fafc8)" do
  # ── Scanner self-coverage — a scan that silently matches nothing must not
  #    be able to pass either assertion below. ───────────────────────────────
  describe "the scanner itself" do
    it "resolves the spec-array indirection in role_modules_seed.rb exactly" do
      result = SeedManifestCoverage.scanned_running_seeds.fetch("role_modules_seed.rb")

      expect(result.names).to eq(%w[docker-runtime nodejs-runtime postgres-server python-runtime redis-cache])
    end

    it "pins which running seeds create NodeModules, so a new creation site cannot slip past" do
      creating = SeedManifestCoverage.scanned_running_seeds
                                     .select { |_file, result| result.creation_sites.positive? }
                                     .keys.sort

      expect(creating).to eq(%w[role_modules_seed.rb]),
        "a running seed gained or lost a System::NodeModule creation site. If a new one appeared, " \
        "confirm the scanner extracts its names (see the UNRESOLVED example) before updating this pin."
    end

    it "leaves no NodeModule creation site unresolved" do
      unresolved = SeedManifestCoverage.scanned_running_seeds
                                       .transform_values(&:unresolved)
                                       .reject { |_file, sites| sites.empty? }

      expect(unresolved).to be_empty,
        "the scanner found System::NodeModule creation sites whose name: argument it cannot resolve — " \
        "it would silently under-report:\n#{unresolved.map { |f, s| "  #{f}: #{s.join(' | ')}" }.join("\n")}"
    end

    it "reads real manifest directories off disk" do
      expect(SeedManifestCoverage.manifest_dirs).to include("powernode-system-base")
      expect(SeedManifestCoverage.manifest_dirs).not_to include("no-such-module-directory")
    end

    it "parses SYSTEM_SEED_FILES out of the orchestrator" do
      listed = SeedManifestCoverage.listed_seed_files

      expect(listed).to include("node_module_catalog.rb", "role_modules_seed.rb")
      missing = listed.reject { |f| File.exist?(File.join(SeedManifestCoverage::SEEDS_PATH, f)) }
      expect(missing).to be_empty, "SYSTEM_SEED_FILES names files that do not exist: #{missing.join(', ')}"
    end

    it "still finds the exclusion patterns documented in the orchestrator" do
      SeedManifestCoverage::DOCUMENTED_PATTERNS.each_key do |label|
        expect(SeedManifestCoverage.orchestrator_source).to include(label),
          "the orchestrator no longer documents the #{label} exclusion — re-derive DOCUMENTED_PATTERNS"
      end
    end
  end

  # ── Assertion (i) ─────────────────────────────────────────────────────────
  describe "(i) every module seeded by a seed that actually runs" do
    it "has a modules/<name>/ manifest directory, or is declared catalog-only" do
      unbacked = SeedManifestCoverage.seeded_module_names.reject do |name|
        SeedManifestCoverage.manifest_dirs.include?(name) ||
          SeedManifestCoverage::CATALOG_ONLY_MODULES.key?(name)
      end

      expect(unbacked).to be_empty,
        "seeded catalog modules with no extensions/system/modules/<name>/ manifest directory — " \
        "System::ModuleBuildPlannerService excludes each as `no_manifest`, so it can never be built:\n" \
        "#{unbacked.map { |n| "  #{n}" }.join("\n")}\n" \
        "Either add the manifest directory or add a CATALOG_ONLY_MODULES entry saying why it is catalog-only."
    end

    it "has no stale CATALOG_ONLY_MODULES entry" do
      seeded = SeedManifestCoverage.seeded_module_names
      stale = SeedManifestCoverage::CATALOG_ONLY_MODULES.keys.filter_map do |name|
        next "#{name} (no longer seeded by a running seed)" unless seeded.include?(name)
        next "#{name} (now HAS modules/#{name}/ — drop the exemption)" if SeedManifestCoverage.manifest_dirs.include?(name)
      end

      expect(stale).to be_empty, "CATALOG_ONLY_MODULES has rotted into a permanent exemption:\n#{stale.join("\n")}"
    end
  end

  # ── Assertion (ii) ────────────────────────────────────────────────────────
  describe "(ii) every db/seeds/*.rb" do
    it "either runs, is a documented exclusion, or is a declared orphan" do
      undeclared = SeedManifestCoverage.orphaned_seeds - SeedManifestCoverage::ORPHANED_SEEDS.keys

      expect(undeclared).to be_empty,
        "db/seeds/*.rb files that never run: not in SYSTEM_SEED_FILES, not matching a documented " \
        "exclusion pattern, not named in the orchestrator, and not a helper of an exempt seed. " \
        "Editing one of these is an inert no-op:\n#{undeclared.map { |f| "  #{f}" }.join("\n")}\n" \
        "Either list it in SYSTEM_SEED_FILES, name it in the orchestrator's exclusion comment, or add " \
        "an ORPHANED_SEEDS entry recording why it is dead."
    end

    it "has no stale ORPHANED_SEEDS entry" do
      orphans = SeedManifestCoverage.orphaned_seeds
      stale = SeedManifestCoverage::ORPHANED_SEEDS.keys.filter_map do |file|
        next "#{file} (no longer exists)" unless SeedManifestCoverage.seed_basenames.include?(file)
        next "#{file} (no longer orphaned — drop the entry)" unless orphans.include?(file)
      end

      expect(stale).to be_empty, "ORPHANED_SEEDS has rotted into a permanent exemption:\n#{stale.join("\n")}"
    end
  end

  # ── Assertion (iii) ───────────────────────────────────────────────────────
  #
  # IMP-3f9bf5594e9c. Assertion (i) reaches only seeds `db:seed` runs, so the
  # operator-invocable seeds — the ones the platform's own error paths tell an
  # operator to run — advertise catalog modules that no assertion here could
  # see. `gpu-nvidia-runtime` is the case that surfaced it.
  #
  # This is an EQUALITY, not an existence check: the declared set must equal
  # the derived gap. An existence check ("every declaration is valid") cannot
  # see a MISSING declaration — an undeclared module just falls through — and
  # cannot see a stale one either, so an entry would ossify into a permanent
  # exemption once the real gap closed. One side is DERIVED (advertised names
  # parsed out of the seed sources, minus the manifest dirs listed off disk);
  # the other is the DECLARATION below, which is hand-written because that is
  # where the reason lives. Symmetry is what makes derived-vs-declared sound:
  # a MISSING entry and a STALE entry both redden.
  describe "(iii) every module an operator-invocable seed advertises" do
    it "has a modules/<name>/ manifest directory, or is a declared gap" do
      expect(SeedManifestCoverage.unbuildable_operator_modules)
        .to match_array(SeedManifestCoverage::UNBUILDABLE_OPERATOR_MODULES.keys),
        "the set of modules advertised by an operator-invocable seed with no " \
        "extensions/system/modules/<name>/ tree no longer equals its declaration. " \
        "System::ModuleBuildPlannerService excludes each as `no_manifest`, so it can never be " \
        "built or published while still appearing assignable.\n" \
        "  derived gap: #{SeedManifestCoverage.unbuildable_operator_modules.inspect}\n" \
        "  declared:    #{SeedManifestCoverage::UNBUILDABLE_OPERATOR_MODULES.keys.sort.inspect}\n" \
        "Add the manifest directory (and DROP the declaration in the same commit), or add a " \
        "UNBUILDABLE_OPERATOR_MODULES entry recording what is missing."
    end

    # ── Anti-vacuity ──────────────────────────────────────────────────────
    # An equality between two derived sets passes trivially when both go
    # empty for the wrong reason — a glob that matches nothing, a parse that
    # extracts nothing. Each side is pinned to a value it can only have if it
    # actually ran.
    it "derives a non-empty operator-invocable seed set that includes a known member" do
      expect(SeedManifestCoverage.operator_invocable_seeds)
        .to include("gpu_nvidia_runtime_module.rb", "sdwan_flow_exporter_module.rb")
      expect(SeedManifestCoverage.operator_invocable_seeds)
        .not_to include("role_modules_seed.rb") # runs on db:seed — assertion (i)'s region
    end

    it "extracts module names from those seeds, including one that IS backed" do
      advertised = SeedManifestCoverage.operator_advertised_module_names

      # sdwan-overlay is advertised by an operator-invocable seed AND has
      # modules/sdwan-overlay/. It can only be here if BOTH sides are live, so
      # it is the pin that stops an empty gap from meaning "nothing was read".
      expect(advertised).to include("sdwan-overlay")
      expect(SeedManifestCoverage.manifest_dirs).to include("sdwan-overlay")
      expect(SeedManifestCoverage.unbuildable_operator_modules).not_to include("sdwan-overlay")
    end

    it "resolves the string-local name form, so a seed using one is not silently missed" do
      result = SeedManifestCoverage.scanned_operator_seeds.fetch("sdwan_flow_exporter_module.rb")

      expect(result.names).to eq(%w[sdwan-flow-exporter])
    end

    # The gpu-nvidia-runtime declaration is a QUOTATION. Pin it to the bytes it
    # quotes, both ways: the seed must still say it (so an edit that softens or
    # deletes the admission reddens here rather than leaving this file asserting
    # a claim its source withdrew), and this file must not have re-authored it.
    it "quotes the gpu-nvidia-runtime admission out of the seed rather than restating it" do
      seed = File.read(File.join(SeedManifestCoverage::SEEDS_PATH, "gpu_nvidia_runtime_module.rb"))
      squish = ->(text) { text.gsub(/\s+/, " ").strip }

      expect(squish.call(seed)).to include(squish.call(SeedManifestCoverage::GPU_NVIDIA_RUNTIME_LIFTED)),
        "the declaration for gpu-nvidia-runtime is no longer a verbatim quotation of " \
        "db/seeds/gpu_nvidia_runtime_module.rb. Either the seed's admission changed (re-lift it) or " \
        "this file re-authored it (don't)."
      expect(SeedManifestCoverage::UNBUILDABLE_OPERATOR_MODULES.fetch("gpu-nvidia-runtime"))
        .to eq(SeedManifestCoverage::GPU_NVIDIA_RUNTIME_LIFTED)
    end

    # Reviewer finding: the unresolved-site declaration is FILE-granular, so a
    # file already named there could gain a second unresolvable creation site
    # and nothing would move. This pins the COUNT per file — the same guard the
    # running-seed region already has ("pins which running seeds create
    # NodeModules") — so a new creation site reddens whether its name resolves
    # or not.
    it "pins how many NodeModule creation sites each operator-invocable seed has" do
      expect(SeedManifestCoverage.operator_creation_site_counts).to eq(
        "docker_runtime_module.rb"        => 2,
        "gpu_nvidia_runtime_module.rb"    => 1,
        "inference_runtime_module.rb"     => 1,
        "k3s_modules.rb"                  => 2,
        "powernode_platform_modules.rb"   => 1,
        "sdwan_flow_exporter_module.rb"   => 1,
        "sdwan_overlay_module.rb"         => 1
      ), "an operator-invocable seed gained or lost a System::NodeModule creation site. Confirm the " \
         "scanner extracts its name (see the UNRESOLVED example) before updating this pin — an " \
         "unresolvable new site would otherwise be invisible to the equality above."
    end

    it "declares every operator-region creation site whose name it cannot resolve" do
      expect(SeedManifestCoverage.unresolved_operator_sites)
        .to match_array(SeedManifestCoverage::UNRESOLVED_MODULE_CREATION_SITES.keys),
        "an operator-invocable seed creates a System::NodeModule whose name: argument the scanner " \
        "cannot resolve. Every such site is a hole in the advertised set above — the equality " \
        "cannot fail for a module it never extracted.\n" \
        "  derived: #{SeedManifestCoverage.unresolved_operator_sites.inspect}\n" \
        "  declared: #{SeedManifestCoverage::UNRESOLVED_MODULE_CREATION_SITES.keys.sort.inspect}"
    end
  end
end
