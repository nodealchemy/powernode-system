# frozen_string_literal: true

require "rails_helper"
require "json"
require "yaml"

# IMP-3855ff9908f2 — the shipped `verify:` blocks, checked against BOTH gates.
#
# A manifest passes through two independent validators: the JSON schema at PR
# time (.gitea/workflows/module-validate.yaml, ajv draft 2020-12, with
# additionalProperties:false at every level) and System::ManifestImportService
# at ingest time. Adding a key to one and not the other does not fail loudly —
# it fails at whichever gate the author is not looking at. This spec runs both
# against every manifest actually shipped in this repo.
#
# It also asserts the two refusals the settled design turns on, at the SCHEMA
# level, because a schema that accepts a probe without `resolves_to` would let
# an existence check reach a fleet node no matter how strict the Ruby is.
RSpec.describe "module manifest schema: verify:" do
  extension_root = File.expand_path("../../..", __dir__)
  schema_path    = File.join(extension_root, "modules/.schema/module-manifest.schema.json")

  let(:schema)        { JSON.parse(File.read(schema_path)) }
  let(:verify_schema) { schema.dig("properties", "verify") }
  let(:probe_schema)  { verify_schema.dig("properties", "probes", "items") }

  manifest_paths = Dir.glob(File.join(extension_root, "modules/*/manifest.yaml")).sort
  with_verify    = manifest_paths.select { |p| YAML.safe_load(File.read(p)).key?("verify") }

  # ECMA-262 anchors are whole-string; Ruby's are line anchors. Translating
  # matters: without it a trailing newline would pass here and fail in CI.
  def whole_string(pattern)
    Regexp.new(pattern.sub(/\A\^/, '\A').sub(/\$\z/, '\z'))
  end

  it "declares the block in the schema at all" do
    expect(verify_schema).to be_a(Hash)
    expect(verify_schema["additionalProperties"]).to be(false)
  end

  # The refusal, at the earliest gate. A schema that made resolves_to optional
  # would let the existence check that passed while VM-9000 was broken through
  # PR review, whatever the importer says later.
  it "REQUIRES resolves_to on every probe" do
    expect(probe_schema["required"]).to include("name", "command", "resolves_to")
    expect(probe_schema["additionalProperties"]).to be(false)
  end

  it "constrains command to a bare name and resolves_to to an absolute path" do
    command_rx = whole_string(probe_schema.dig("properties", "command", "pattern"))
    expect(command_rx.match?("gh")).to be(true)
    # A path command resolves itself and never exercises the PATH lookup.
    expect(command_rx.match?("/usr/local/bin/gh")).to be(false)
    expect(command_rx.match?("gh; id")).to be(false)

    resolves_rx = whole_string(probe_schema.dig("properties", "resolves_to", "pattern"))
    expect(resolves_rx.match?("/usr/local/bin/gh")).to be(true)
    expect(resolves_rx.match?("bin/gh")).to be(false)
  end

  it "has no shells key — the two-shell rule is not configurable" do
    expect(verify_schema["properties"].keys).to eq([ "probes" ])
    expect(probe_schema["properties"].keys).to contain_exactly("name", "command", "resolves_to")
  end

  # Consumer-first: this feature is pointless if nothing declares a probe.
  it "is actually declared by at least one shipped module" do
    expect(with_verify).not_to be_empty,
      "no shipped manifest carries a verify: block — a probe primitive nothing uses " \
      "is the half-lane shape this work exists to avoid"
  end

  describe "every shipped verify: block" do
    with_verify.each do |path|
      relative = path.split("/extensions/system/").last
      manifest = YAML.safe_load(File.read(path))

      it "#{relative} satisfies the schema's own patterns" do
        probes = manifest.dig("verify", "probes")
        expect(probes).to be_an(Array).and be_present

        command_rx  = whole_string(probe_schema.dig("properties", "command", "pattern"))
        resolves_rx = whole_string(probe_schema.dig("properties", "resolves_to", "pattern"))
        name_rx     = whole_string(probe_schema.dig("properties", "name", "pattern"))

        probes.each do |probe|
          expect(probe.keys).to all(be_in(probe_schema["properties"].keys))
          expect(name_rx.match?(probe["name"].to_s)).to be(true), "bad name #{probe['name'].inspect}"
          expect(command_rx.match?(probe["command"].to_s)).to be(true), "bad command #{probe['command'].inspect}"
          expect(resolves_rx.match?(probe["resolves_to"].to_s)).to be(true),
            "bad resolves_to #{probe['resolves_to'].inspect}"
        end
      end

      it "#{relative} survives ManifestImportService validation and ModuleVerify parsing" do
        account  = create(:account)
        platform = create(:system_node_platform, account: account)
        category = create(:system_node_module_category, account: account)
        mod = create(:system_node_module, account: account, node_platform: platform,
                     category: category, variety: "subscription", name: manifest["name"])

        result = System::ManifestImportService.validate_only(yaml: File.read(path), node_module: mod)
        expect(result.validation_errors.grep(/verify/)).to be_empty

        # And the declaration the agent will read is the one the author wrote —
        # a probe silently dropped by the parser is a module that reports
        # nothing while looking verified.
        parsed = System::ModuleVerify.probes_from(manifest["verify"])
        expect(parsed.size).to eq(manifest.dig("verify", "probes").size)
      end
    end
  end
end
