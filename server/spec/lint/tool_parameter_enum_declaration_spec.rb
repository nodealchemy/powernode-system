# frozen_string_literal: true

require "rails_helper"

# IMP-40548751c199 (APO-8a, extension half) — the eight System-extension MCP
# tool surfaces stated every closed value set in ENGLISH and nothing else.
# `target_state` said "staging | blessed | live | retired" in its description;
# `owner_kind` said "service_user | operator | nobody | root"; thirty-nine
# array parameters said nothing about their element type at all. A strict MCP
# client got `{"type":"string"}` / `{"type":"array"}` and had to recover the
# contract by parsing prose.
#
# The core half (IMP-e809396f9eda, fbae03c80) taught Ai::Tools::ParameterSchema
# to carry `enum` / `items` / `default` / `properties` onto the wire, so a
# declaration now actually reaches the client. This guard is the ratchet that
# keeps the declarations in place once they are there.
#
# WHERE THE VALUES COME FROM (and why this file re-derives them): the accepted
# set is whatever the dispatch `case` and the model/executor `inclusion:`
# validators accept — never the description prose, which is the thing that
# rotted. Two of the prose lists were already WRONG when this guard was
# written: `target_state` omitted "built" (a real System::NodeModuleVersion
# PROMOTION_TRANSITIONS target out of "staging"), and the subnet-advertisement
# `source` filter omitted "pod_subnet". The positive control below therefore
# compares against the model constants, not against a copy of the list.
#
# The four checks are deliberately different in kind:
#   1. vacuity floor      — the walker must actually find the surface, so a
#                           refactor that renames `action_definitions` fails
#                           loudly instead of passing over an empty set.
#   2. items coverage     — every array parameter declares an element type.
#   3. prose coverage     — a description that still SPELLS a closed set must
#                           back it with `enum:` (or, for an object whose closed
#                           set is its KEY set, with `properties:`).
#   4. positive control   — a named sample must carry the EXACT accepted values,
#                           so "declared something" cannot pass for "declared
#                           the right thing".
# Everything this guard needs to KNOW (as opposed to compute) lives in one
# namespaced module: a constant assigned inside an RSpec block lands on Object,
# and `Row` in particular is a name any other spec could reasonably claim.
module ToolEnumLint
  TOOLS_DIR = File.expand_path("../../app/services/ai/tools", __dir__)

  # tool class => source basename. Every tool this campaign half converted.
  TOOL_SOURCES = {
    "Ai::Tools::SystemFleetTool"               => "system_fleet_tool.rb",
    "Ai::Tools::SdwanTool"                     => "sdwan_tool.rb",
    "Ai::Tools::SystemIngressTool"             => "system_ingress_tool.rb",
    "Ai::Tools::SystemAcmeTool"                => "system_acme_tool.rb",
    "Ai::Tools::SystemPackageRepositoryTool"   => "system_package_repository_tool.rb",
    "Ai::Tools::SystemArchitectureCatalogTool" => "system_architecture_catalog_tool.rb",
    "Ai::Tools::SystemStorageOwnerTool"        => "system_storage_owner_tool.rb",
    "Ai::Tools::SystemBlastRadiusTool"         => "system_blast_radius_tool.rb"
  }.freeze

  # Floors, not counts. Each sits materially BELOW the live number (911
  # parameter rows / 39 array rows / 92 enum rows, counted 2026-09-02) so that
  # removing a parameter does not turn this example red for a reason unrelated
  # to the invariant, while an empty or truncated walk still fails. A floor set
  # EQUAL to the live count would be a churn trap, not a floor.
  MIN_PARAMETER_ROWS = 800
  MIN_ARRAY_ROWS     = 30
  MIN_ENUM_ROWS      = 60

  # A description that spells a closed value set. Three shapes: "One of:" prose,
  # a spaced pipe list, and an UNSPACED pipe list. The unspaced shape is not
  # cosmetic — the first pass of this conversion missed six parameters
  # (`severity`, `lifecycle_class`, two `status` filters, `state`, `feed_source`)
  # precisely because the detector only saw spaced pipes, so a set written
  # `a|b|c` sailed straight past the ratchet.
  #
  # A slash-separated shape (`leased/registered/busy`) is deliberately NOT
  # matched: by shape alone it is indistinguishable from a path or a field
  # list, and when it was tried here both of its matches were false positives
  # (`docs/runbooks/module-authoring.md` and a
  # `mask/file_spec/package_spec/dependency_spec` field list) against zero real
  # ones. The slash-written sets that DID exist were normalised to pipes by
  # this conversion, which is where the coverage comes from.
  PROSE_ENUM_SHAPES = [
    /\bone of\b/i,
    /\S\s\|\s\S/,
    /[a-z0-9_]\|[a-z0-9_]/
  ].freeze

  # A candidate value set spelled inside a free-text description: two or more
  # identifier-shaped tokens separated by pipes.
  PROSE_SET_SHAPE = /(?<![\w"'])[a-z][a-z0-9_]*(?:\s*\|\s*[a-z][a-z0-9_]*)+(?![\w"'])/

  # Prose-shaped descriptions with NO code-side oracle to convert against.
  # Each entry is [tool, action, parameter] => why. Keying on the triple means
  # a rename forces re-acknowledgement rather than silently widening the
  # exemption. `action` is "__definition__" for a tool-level parameter.
  PROSE_WITHOUT_ENUM = {
    ["Ai::Tools::SystemFleetTool", "system_create_volume", "nfs_version"] =>
      "No server-side validator: the value is interpolated straight into " \
      "`nfsvers=` in the mount options, so the accepted set belongs to the " \
      "NFS client on the node, not to the platform.",
    ["Ai::Tools::SystemFleetTool", "system_lease_ci_runner", "pool_name"] =>
      "The 'One of pool_name/pool_id is required' phrasing names two " \
      "PARAMETERS, not two accepted values — there is no value set here.",
    ["Ai::Tools::SystemFleetTool", "system_create_provider", "provider_type"] =>
      "The accepted set is the runtime provider registry (supported? / " \
      "sdk_available?), which varies with the gems installed on the node — " \
      "a static enum would be wrong on some deployments.",
    ["Ai::Tools::SystemFleetTool", "system_create_cve", "feed_source"] =>
      "System::Cve has no feed_source validator and the column is free-form: " \
      "CveOps::FeedIngestService writes whatever `source` the feed run names, " \
      "and the CVE drill seeds write \"DRILL\". nvd/ghsa/manual is a naming " \
      "CONVENTION, so an enum would forbid values the platform itself writes.",
    ["Ai::Tools::SystemPackageRepositoryTool", "system_search_packages", "sort"] =>
      "Inert: System::PackageSearchService reads `sort` only to echo it back " \
      "in the result payload; no ordering branch consumes it, so there is no " \
      "accepted set to pin. Queued separately as a behaviour gap."
  }.freeze

  Row = Struct.new(:tool, :action, :name, :spec, keyword_init: true) do
    def label = "#{tool}##{action}[#{name}]"
    def fetch(key) = spec[key.to_sym].nil? ? spec[key.to_s] : spec[key.to_sym]
    def type = fetch(:type).to_s
    def description = fetch(:description).to_s
  end
end

RSpec.describe "Extension MCP tool parameter enum/items declarations" do
  # Named sample carrying the EXACT accepted values. Compared against the
  # model/executor constant the dispatch path actually validates on, so a
  # declaration that merely exists cannot pass for a correct one.
  def positive_control_expectations
    [
      ["Ai::Tools::SystemFleetTool", "system_promote_module_version", "target_state",
       ::System::NodeModuleVersion::PROMOTION_STATES],
      ["Ai::Tools::SystemFleetTool", "system_update_instance_pool", "status",
       ::System::InstancePool::STATUSES],
      ["Ai::Tools::SdwanTool", "system_sdwan_create_firewall_rule", "firewall_action",
       ::Sdwan::FirewallRule::ACTIONS],
      ["Ai::Tools::SdwanTool", "system_sdwan_list_subnet_advertisements", "source",
       ::Sdwan::SubnetAdvertisement::SOURCES],
      ["Ai::Tools::SystemIngressTool", "system_create_service", "protocol",
       ::Sdwan::Service::PROTOCOLS],
      ["Ai::Tools::SystemAcmeTool", "system_acme_create_dns_credential", "provider",
       ::System::AcmeDnsCredential::SUPPORTED_PROVIDERS],
      ["Ai::Tools::SystemPackageRepositoryTool", "system_search_packages", "kind",
       ::System::PackageRepository::KINDS],
      ["Ai::Tools::SystemArchitectureCatalogTool", "system_create_architecture", "family",
       ::System::NodeArchitecture::FAMILIES],
      ["Ai::Tools::SystemStorageOwnerTool", "system_assign_storage_owner", "owner_kind",
       ::System::StorageAssignment::OWNER_KINDS],

      # The three sets with the WEAKEST upstream oracle get a control each,
      # because they are the ones most likely to drift unnoticed:
      #   `op` cites a constant in a file another lane rewrites often;
      #   `transport` is the tool's OWN allow-list (no model validator);
      #   `mode` is a constant this campaign extracted out of an inline literal.
      ["Ai::Tools::SystemFleetTool", "system_platform_resilience", "op",
       ::System::Ai::Skills::PlatformResilienceExecutor::ACTIONS],
      ["Ai::Tools::SystemFleetTool", "system_create_volume", "transport",
       ::Ai::Tools::SystemFleetTool::VOLUME_TRANSPORTS],
      ["Ai::Tools::SystemPackageRepositoryTool", "system_search_packages", "mode",
       ::System::PackageSearchService::MODES]
    ]
  end

  # Walks both parameter surfaces a tool advertises: the tool-level
  # `definition[:parameters]` (what a non-action-aware client sees) and each
  # entry of `action_definitions` (what the per-action MCP tools carry).
  def parameter_rows
    @parameter_rows ||= ToolEnumLint::TOOL_SOURCES.keys.flat_map do |tool|
      klass = tool.constantize
      rows = []

      definition = klass.respond_to?(:definition) ? klass.definition : nil
      if definition.is_a?(Hash) && definition[:parameters].is_a?(Hash)
        definition[:parameters].each do |name, spec|
          rows << ToolEnumLint::Row.new(tool: tool, action: "__definition__", name: name.to_s, spec: spec) if spec.is_a?(Hash)
        end
      end

      if klass.respond_to?(:action_definitions)
        (klass.action_definitions || {}).each do |action, action_def|
          next unless action_def.is_a?(Hash) && action_def[:parameters].is_a?(Hash)

          action_def[:parameters].each do |name, spec|
            rows << ToolEnumLint::Row.new(tool: tool, action: action.to_s, name: name.to_s, spec: spec) if spec.is_a?(Hash)
          end
        end
      end

      rows
    end
  end

  def row_for(tool, action, name)
    parameter_rows.find { |r| r.tool == tool && r.action == action && r.name == name }
  end

  # The set of action names the tool's dispatch actually accepts.
  #
  # For seven of the eight this is parsed out of the `def call` body's `case`
  # so the oracle is independent of `action_definitions` (the thing the enum is
  # built from). SystemIngressTool dispatches off two CONSTANTS instead of a
  # `case` — `ACTION_EXECUTORS.key?(action) || INLINE_ACTIONS.key?(action)` is
  # literally the guard in its #call — so those constants are its dispatch set.
  def dispatch_actions_for(tool)
    klass = tool.constantize
    if klass.const_defined?(:ACTION_EXECUTORS, false) && klass.const_defined?(:INLINE_ACTIONS, false)
      return (klass.const_get(:ACTION_EXECUTORS).keys + klass.const_get(:INLINE_ACTIONS).keys).map(&:to_s)
    end

    source = File.read(File.join(ToolEnumLint::TOOLS_DIR, ToolEnumLint::TOOL_SOURCES.fetch(tool)))
    head = source.index(/^      def call\(params\)/)
    return [] if head.nil?

    body = source[head..]
    tail = body.index(/\n      (?:private|protected)\b/) || body.length
    body[0, tail]
      .scan(/^\s*when\s+((?:"[^"]+"\s*,?\s*)+)then/)
      .flatten
      .flat_map { |clause| clause.scan(/"([^"]+)"/).flatten }
  end

  it "walks a non-vacuous parameter surface" do
    expect(parameter_rows.size).to be >= ToolEnumLint::MIN_PARAMETER_ROWS

    arrays = parameter_rows.select { |r| r.type == "array" }
    expect(arrays.size).to be >= ToolEnumLint::MIN_ARRAY_ROWS

    with_enum = parameter_rows.select { |r| r.fetch(:enum).is_a?(Array) }
    expect(with_enum.size).to be >= ToolEnumLint::MIN_ENUM_ROWS
  end

  it "declares items: on every array-typed parameter" do
    offenders = parameter_rows.select { |r| r.type == "array" }.reject do |r|
      items = r.fetch(:items)
      items.is_a?(Hash) && (items[:type] || items["type"]).present?
    end

    expect(offenders.map(&:label)).to eq([]),
      "array parameters reach a strict MCP client untyped — declare " \
      "items: { type: ... }:\n  #{offenders.map(&:label).join("\n  ")}"
  end

  it "backs every prose-stated closed value set with enum: (or properties: for an object)" do
    offenders = parameter_rows.select { |r|
      ToolEnumLint::PROSE_ENUM_SHAPES.any? { |shape| r.description.match?(shape) }
    }.reject { |r|
      ToolEnumLint::PROSE_WITHOUT_ENUM.key?([r.tool, r.action, r.name])
    }.reject { |r|
      enum = r.fetch(:enum)
      next true if enum.is_a?(Array) && enum.any?

      props = r.fetch(:properties)
      r.type == "object" && props.is_a?(Hash) && props.any?
    }

    expect(offenders.map(&:label)).to eq([]),
      "these descriptions still state a closed value set only in English:\n  " \
      "#{offenders.map { |r| "#{r.label} — #{r.description[0, 120]}" }.join("\n  ")}"
  end

  # An action DESCRIPTION is a second place the same set gets spelled, and it is
  # not a parameter row, so the prose check above cannot see it. This is not
  # hypothetical: the promote-module-version description kept saying
  # "(staging|blessed|live|retired)" for a whole conversion pass after the
  # parameter three lines below it had been corrected to include "built" —
  # and the public catalog republished the wrong list.
  it "does not spell a value set in an action description that contradicts the declared enum" do
    offenders = ToolEnumLint::TOOL_SOURCES.keys.flat_map do |tool|
      klass = tool.constantize
      next [] unless klass.respond_to?(:action_definitions)

      declared_by_action = parameter_rows.group_by(&:action).transform_values do |rows|
        rows.filter_map { |r| Array(r.fetch(:enum)).map(&:to_s) if r.fetch(:enum).is_a?(Array) }
      end

      (klass.action_definitions || {}).flat_map do |action, action_def|
        description = action_def.is_a?(Hash) ? action_def[:description].to_s : ""
        enums = declared_by_action[action.to_s] || []

        description.scan(ToolEnumLint::PROSE_SET_SHAPE).filter_map do |candidate|
          spelled = candidate.split("|").map(&:strip).sort
          next if spelled.size < 3

          # Only a set the action itself declares is an oracle: overlap of two
          # or more values identifies WHICH enum the prose is restating.
          match = enums.find { |enum| (enum & spelled).size >= 2 }
          next if match.nil? || match.sort == spelled

          "#{tool}##{action}: description says #{spelled.inspect} but the action declares #{match.sort.inspect}"
        end
      end
    end

    expect(offenders).to eq([])
  end

  it "pins the tool-level action parameter's enum to the dispatch-accepted set" do
    mismatches = ToolEnumLint::TOOL_SOURCES.keys.filter_map do |tool|
      row = row_for(tool, "__definition__", "action")
      next if row.nil?

      declared = Array(row.fetch(:enum)).map(&:to_s)
      dispatch = dispatch_actions_for(tool)
      next if declared.sort == dispatch.sort && dispatch.any?

      "#{tool}: enum=#{declared.sort.inspect} dispatch=#{dispatch.sort.inspect}"
    end

    expect(mismatches).to eq([])
  end

  it "carries the exact accepted values on the named sample (positive control)" do
    mismatches = positive_control_expectations.filter_map do |tool, action, name, expected|
      row = row_for(tool, action, name)
      next "#{tool}##{action}[#{name}]: parameter not found" if row.nil?

      declared = Array(row.fetch(:enum)).map(&:to_s)
      next if declared.sort == expected.map(&:to_s).sort

      "#{tool}##{action}[#{name}]: enum=#{declared.sort.inspect} expected=#{expected.sort.inspect}"
    end

    expect(mismatches).to eq([])
  end

  it "carries an object element type on an array of hashes (positive control)" do
    row = row_for("Ai::Tools::SdwanTool", "system_sdwan_federation_compose", "peers")
    expect(row).not_to be_nil
    expect((row.fetch(:items) || {})[:type] || (row.fetch(:items) || {})["type"]).to eq("object")
  end
end
