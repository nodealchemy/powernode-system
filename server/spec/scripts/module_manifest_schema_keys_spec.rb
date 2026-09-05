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

  # 2026-09-05: the SAME failure recurred one rung up. `restart_after_update`
  # was added to KNOWN_TOP_KEYS and to ModuleConfigValidator, shipped in
  # powernode-extension-system/manifest.yaml, and never declared in the
  # schema — whose top level is also additionalProperties:false. Every push
  # to develop from 2026-08-26 on failed module-validate on that one key, so
  # the gate was saturated and could no longer surface a NEW manifest error.
  #
  # The two invariants above close the class for `build.*` only. These close
  # it for the top level, deriving the accepted set from the importer rather
  # than restating it, so the two cannot drift.
  describe "top-level keys" do
    let(:declared_top_keys) { schema.fetch("properties").keys.sort }

    # Read from SOURCE, not from the loaded constant: this file requires
    # spec_helper, so ::System is only defined when some sibling spec in the
    # same run happened to boot Rails first. Referencing the constant made
    # this example pass or NameError depending on run composition, which is
    # the order-dependent green the ratchet guards exist to avoid.
    let(:importer_known_top_keys) do
      src = File.read(File.join(extension_root, "server/app/services/system/manifest_import_service.rb"))
      body = src[/KNOWN_TOP_KEYS\s*=\s*%w\[(.*?)\]/m, 1]
      raise "KNOWN_TOP_KEYS not found in manifest_import_service.rb — this guard's " \
            "derivation has drifted and would otherwise pass vacuously" if body.nil?

      keys = body.split(/\s+/).reject(&:empty?)
      raise "KNOWN_TOP_KEYS parsed empty" if keys.empty?

      keys
    end

    it "declares every top-level key ManifestImportService recognizes" do
      undeclared = importer_known_top_keys - declared_top_keys
      expect(undeclared).to be_empty,
        "ManifestImportService::KNOWN_TOP_KEYS accepts keys the schema forbids " \
        "(additionalProperties:false), so ajv rejects any manifest using them: #{undeclared.inspect}"
    end

    it "declares every top-level key any shipped manifest carries" do
      offenders = Dir[File.join(extension_root, "modules/*/manifest.yaml")]
                  .concat(Dir[File.join(extension_root, "templates/**/manifest.yaml")])
                  .filter_map do |path|
        doc = YAML.safe_load(File.read(path), aliases: true)
        next unless doc.is_a?(Hash)

        extra = doc.keys - declared_top_keys
        [ path.split("/extensions/system/").last, extra ] if extra.any?
      end
      expect(offenders).to be_empty,
        "shipped manifests declare top-level keys ajv will reject: #{offenders.inspect}"
    end
  end

  it "declares every build key any shipped manifest carries" do
    offenders = Dir[File.join(extension_root, "modules/*/manifest.yaml")].filter_map do |path|
      build = (YAML.safe_load(File.read(path), aliases: true) || {})["build"]
      next unless build.is_a?(Hash)

      extra = build.keys - declared_build_keys
      [ File.basename(File.dirname(path)), extra ] if extra.any?
    end
    expect(offenders).to be_empty,
      "shipped manifests declare build keys ajv will reject: #{offenders.inspect}"
  end
end
