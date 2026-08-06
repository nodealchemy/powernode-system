# frozen_string_literal: true

require "spec_helper"
require "json"
require "yaml"

# IMP-e06303b287d8 — the manifest schema's `build` object declares
# additionalProperties:false, while stage15.sh read two keys the schema
# forbade (go_version, claude_code_version) and two SHIPPED manifests
# declared exactly those keys — so module-validate's ajv run either failed
# on them or had never seen them. Deleting the keys from the manifests to
# make CI green would be the worst outcome: the scripts' `// "default"` jq
# fallback silently unpins both versions. These invariants close the CLASS:
# every build key the scripts read, and every build key a shipped manifest
# declares, must be declared in the schema.
RSpec.describe "module manifest build-key schema agreement" do
  let(:extension_root) { File.expand_path("../../..", __dir__) }
  let(:schema) do
    JSON.parse(File.read(File.join(extension_root, "modules/.schema/module-manifest.schema.json")))
  end
  let(:declared_build_keys) { schema.dig("properties", "build", "properties").keys.sort }

  it "declares every .build key the build scripts read" do
    # Only jq reads count — a bare `.build.` regex also matches the filename
    # vite.config.build.ts, which appears in these very scripts (the known
    # false positive the original sweep hit too).
    script_reads = Dir[File.join(extension_root, "scripts/module-build/*.sh")]
                   .flat_map { |f| File.read(f).lines.grep(/\bjq\b/) }
                   .flat_map { |line| line.scan(/\.build\.([a-z0-9_]+)/).flatten }
                   .uniq.sort
    undeclared = script_reads - declared_build_keys
    expect(undeclared).to be_empty,
      "build scripts read manifest keys the schema forbids " \
      "(additionalProperties:false): #{undeclared.inspect}"
  end

  it "declares every build key any shipped manifest carries" do
    offenders = Dir[File.join(extension_root, "modules/*/manifest.yaml")].filter_map do |path|
      build = (YAML.safe_load(File.read(path), aliases: true) || {})["build"]
      next unless build.is_a?(Hash)

      extra = build.keys - declared_build_keys
      [File.basename(File.dirname(path)), extra] if extra.any?
    end
    expect(offenders).to be_empty,
      "shipped manifests declare build keys ajv will reject: #{offenders.inspect}"
  end
end
