# frozen_string_literal: true

require "rails_helper"
require "yaml"
require "tmpdir"

# IMP-7cacd5924fc9 — the one `fleet.yaml` example tutorial 10 is built around
# was rejected wholesale by the platform's own schema. It carried five
# top-level keys (version, account, templates, nodes, sdwan); the validator
# permits seven others (templates, assignments, modules, provider_configs,
# pools, platforms, fleet), reported four of the five as "unknown top-level
# key", and rejected `templates` too because the doc wrote it as a list where
# the validator wants a mapping of name → attributes. Five errors, so
# `DesiredStateParser#parse!` returned `ok?: false` and a sync of that file
# computed no diff and applied NOTHING — while the tutorial's stated outcome
# was "YAML validates locally".
#
# Two of the five were not merely mis-shaped, they were INEXPRESSIBLE: GitOps
# has no `node` kind and no `sdwan` kind. `ApplyService#apply_diff` dispatches
# template / module / assignment / pool / platform / provider_config and raises
# `UnsupportedDiffError` otherwise; `DiffEngine` emits diffs for exactly those
# kinds. A tutorial teaching `nodes:` / `sdwan:` blocks teaches a file the
# reconciler can never converge, however the block is spelled.
#
# WHY THIS FILE AND NOT THE SIGNATURE ENUMERATOR: 10-gitops-fleet.md is in
# module_docs_mcp_call_signatures_spec.rb COVERED_DOCS and carried this for its
# whole life, because that parser reads `platform.<verb>({ ... })` call sites
# and a YAML block is not one. The oracle here is the strongest one available:
# the doc's ACTUAL bytes, run through the REAL validator, the REAL parser, and
# the REAL diff engine — not a hand-copied fixture that can drift from the doc.
#
# The kind sets are PARSED from the two services' source rather than listed
# here, so adding a kind to one service and not the other (or to the tutorial
# and neither service) reddens without anyone remembering to update a literal.
module GitopsFleetYamlTutorialDocs
  TUTORIAL = "docs/tutorials/10-gitops-fleet.md"
  APPLY_SERVICE = "server/app/services/system/gitops/apply_service.rb"
  DIFF_ENGINE = "server/app/services/system/gitops/diff_engine.rb"

  # fleet.yaml section → the DiffEngine/ApplyService kind it becomes. `fleet`
  # is the one allowed top-level key that is NOT a resource section (it holds
  # defaults the validator checks and the parser ignores), so it has no kind.
  SECTION_KINDS = {
    "templates" => "template",
    "modules" => "module",
    "assignments" => "assignment",
    "pools" => "pool",
    "platforms" => "platform",
    "provider_configs" => "provider_config"
  }.freeze
end

RSpec.describe "Tutorial 10 fleet.yaml vs. the real GitOps schema" do
  ext_root = File.expand_path("../../..", __dir__)

  def self.read(ext_root, rel)
    path = File.join(ext_root, rel)
    raise "expected #{rel} to exist under #{ext_root}" unless File.exist?(path)

    File.read(path)
  end

  # The example is the yaml fence whose first line is the `# fleet.yaml`
  # header — anchored on the header so a second yaml block added elsewhere in
  # the tutorial can neither shadow it nor be mistaken for it.
  def self.fleet_yaml_block(doc)
    doc[/^```yaml\n(# fleet\.yaml\n.*?)^```/m, 1]
  end

  # Every `kind == "<x>"` comparison inside ApplyService#apply_diff — the
  # dispatch table, read from the method body rather than restated.
  def self.dispatched_kinds(src)
    body = src[/def apply_diff\(.*?\n(.*?)^\s*def /m, 1]
    raise "ApplyService#apply_diff not found — dispatch oracle would be vacuous" if body.nil?

    body.scan(/kind == "(\w+)"/).flatten.uniq.sort
  end

  # Every `kind: "<x>"` DiffEngine constructs a Diff with.
  def self.diffed_kinds(src)
    kinds = src.scan(/kind: "(\w+)"/).flatten.uniq.sort
    raise "DiffEngine constructs no Diff with a literal kind — oracle would be vacuous" if kinds.empty?

    kinds
  end

  let(:doc) { self.class.read(ext_root, GitopsFleetYamlTutorialDocs::TUTORIAL) }
  let(:block) { self.class.fleet_yaml_block(doc) }
  let(:raw) { YAML.safe_load(block, permitted_classes: [ Symbol, Date, Time ], aliases: true) }

  it "has exactly one `# fleet.yaml` example block" do
    expect(doc.scan(/^```yaml\n# fleet\.yaml\n/).size).to eq(1)
    expect(block).not_to be_nil
  end

  it "passes System::Gitops::DesiredStateValidator with no errors" do
    result = System::Gitops::DesiredStateValidator.call(raw)

    expect(result.errors).to eq({})
    expect(result.ok?).to be true
  end

  it "parses through System::Gitops::DesiredStateParser into a non-empty DesiredState" do
    Dir.mktmpdir("gitops-tutorial") do |work_tree|
      File.write(File.join(work_tree, "fleet.yaml"), block)
      result = System::Gitops::DesiredStateParser.parse!(work_tree_path: work_tree)

      expect(result.error).to be_nil
      expect(result.ok?).to be true
      expect(result.desired_state).not_to be_empty
      # Every section the tutorial declares survives parsing as a name-keyed
      # mapping — a list-shaped section would come out re-keyed or empty.
      raw.except("fleet").each do |section, entries|
        expect(result.desired_state.public_send(section).keys).to eq(entries.keys),
                                                                    "section #{section} did not round-trip"
      end
    end
  end

  it "declares only sections that map to a kind both DiffEngine diffs and ApplyService dispatches" do
    dispatched = self.class.dispatched_kinds(self.class.read(ext_root, GitopsFleetYamlTutorialDocs::APPLY_SERVICE))
    diffed = self.class.diffed_kinds(self.class.read(ext_root, GitopsFleetYamlTutorialDocs::DIFF_ENGINE))

    sections = raw.keys - [ "fleet" ]
    expect(sections).not_to be_empty
    sections.each do |section|
      kind = GitopsFleetYamlTutorialDocs::SECTION_KINDS[section]
      expect(kind).not_to be_nil, "#{section}: is not a GitOps resource section"
      expect(diffed).to include(kind), "#{section}: DiffEngine never emits kind=#{kind}"
      expect(dispatched).to include(kind), "#{section}: ApplyService#apply_diff raises UnsupportedDiffError for kind=#{kind}"
    end
  end

  it "resolves every cross-reference inside the file, the way ApplyService resolves it at apply time" do
    templates = raw.fetch("templates")
    modules = raw.fetch("modules", {})

    # apply_template create: `desired.node_platform` is required.
    templates.each do |name, attrs|
      expect(attrs["node_platform"]).to be_a(String), "templates.#{name}: apply_template create requires node_platform"
    end

    # apply_pool / apply_platform create: resolve_node_template! by NAME.
    %w[pools platforms].each do |section|
      raw.fetch(section, {}).each do |name, attrs|
        expect(templates).to have_key(attrs["node_template"]),
                             "#{section}.#{name}: node_template #{attrs['node_template'].inspect} is not declared in templates"
      end
    end

    # apply_assignment create: `desired.template` + `desired.module` by NAME,
    # and the validator wants the key in `<name>:<module>` form.
    raw.fetch("assignments", {}).each do |key, attrs|
      expect(templates).to have_key(attrs["template"]), "assignments.#{key}: template not declared"
      expect(modules).to have_key(attrs["module"]), "assignments.#{key}: module not declared"
      expect(key.split(":", 2).last).to eq(attrs["module"]), "assignments.#{key}: key does not end in the module name"
    end

    # `variety` must satisfy the MODEL, not just the validator:
    # DesiredStateValidator::MODULE_VARIETIES also permits "role", which
    # NodeModule::VARIETIES and the system_node_modules_variety_check
    # constraint both reject — apply_module passes the value straight into
    # NodeModule.create!, so a validator-legal "role" raises RecordInvalid.
    modules.each do |name, attrs|
      next unless attrs.key?("variety")

      expect(::System::NodeModule::VARIETIES).to include(attrs["variety"]),
                                                 "modules.#{name}: variety #{attrs['variety'].inspect} is not in NodeModule::VARIETIES " \
                                                 "(#{::System::NodeModule::VARIETIES.join('|')}) — it would fail at apply, not at validation"
    end

    # The pool knob the tutorial teaches must be one the model accepts.
    raw.fetch("pools", {}).each do |name, attrs|
      next unless attrs.key?("lifecycle_class")

      expect(::System::InstancePool::LIFECYCLE_CLASSES).to include(attrs["lifecycle_class"]),
                                                            "pools.#{name}: lifecycle_class not in the model's set"
    end
  end

  it "diffs against an empty account into create diffs of dispatchable kinds only" do
    account = create(:account)
    # Account bootstrap seeds templates + modules; clear them so the diff is
    # the tutorial's file against nothing, not against onboarding defaults.
    ::System::NodeModuleAssignment.joins(:node).where(system_nodes: { account_id: account.id }).destroy_all
    ::System::NodeTemplate.where(account: account).destroy_all
    ::System::NodeModule.where(account: account).update_all(current_version_id: nil)
    ::System::NodeModule.where(account: account).destroy_all

    desired_state = Dir.mktmpdir("gitops-tutorial") do |work_tree|
      File.write(File.join(work_tree, "fleet.yaml"), block)
      parsed = System::Gitops::DesiredStateParser.parse!(work_tree_path: work_tree)
      expect(parsed.error).to be_nil
      parsed.desired_state
    end

    # apply_template resolves desired.node_platform by NAME and raises
    # StaleConflictError when it misses, so a name no account bootstrap seeds
    # is a tutorial that fails on its very first apply.
    raw.fetch("templates").each do |name, attrs|
      expect(::System::NodePlatform.find_by(account_id: account.id, name: attrs["node_platform"]))
        .not_to(be_nil,
                "templates.#{name}: node_platform #{attrs['node_platform'].inspect} exists in no bootstrapped account — " \
                "apply_template would raise StaleConflictError")
    end

    result = System::Gitops::DiffEngine.diff!(account: account, desired_state: desired_state)

    expect(result.error).to be_nil
    expect(result.ok?).to be true
    expect(result.diffs).not_to be_empty
    dispatched = self.class.dispatched_kinds(self.class.read(ext_root, GitopsFleetYamlTutorialDocs::APPLY_SERVICE))
    result.diffs.each do |diff|
      expect(dispatched).to include(diff.kind), "diff #{diff.name}: kind=#{diff.kind} is not dispatchable"
      expect(%i[create informational]).to include(diff.change), "diff #{diff.name}: unexpected change=#{diff.change}"
    end
    expect(result.diffs.map(&:kind).uniq.sort)
      .to eq((raw.keys - [ "fleet" ]).map { |s| GitopsFleetYamlTutorialDocs::SECTION_KINDS[s] }.sort)
  end
end
