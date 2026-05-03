# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::ManifestImportService, type: :service do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }
  let(:mod) do
    create(:system_node_module, account: account, node_platform: platform,
           category: category, variety: "subscription", name: "demo-mod")
  end

  let(:manifest_yaml) do
    <<~YAML
      schema_version: 1
      name: demo-mod
      display_name: "Demo Module"
      description: "Demo manifest for import-service tests."
      license: "MIT"
      mask:
        - "/var/cache/apt/**"
      file_spec:
        - "/etc/demo/**"
        - "/usr/bin/demo"
      package_spec:
        - "demo"
        - "demo-extras"
      dependency_spec:
        - "/etc/demo/dep"
      protected_spec:
        - "/etc/demo/secret"
      dependencies:
        requires: []
        provides:
          - demo.service
      init:
        start: "systemctl start demo"
        stop: "systemctl stop demo"
        restart: "systemctl reload demo"
      reboot_required: false
      security:
        capabilities:
          - CAP_NET_BIND_SERVICE
        egress_allow: []
        privileged: false
      skills: []
      build:
        ubuntu_digest: null
        apt_snapshot: "20260415T000000Z"
    YAML
  end

  describe "#import!" do
    it "writes spec + lifecycle fields onto the module" do
      result = described_class.import!(node_module: mod, yaml: manifest_yaml)

      expect(result.ok?).to be true
      mod.reload
      expect(mod.mask_text).to            include("/var/cache/apt/**")
      expect(mod.file_spec_text).to       include("/etc/demo/**", "/usr/bin/demo")
      expect(mod.package_spec_text).to    include("demo", "demo-extras")
      expect(mod.dependency_spec_text).to include("/etc/demo/dep")
      expect(mod.protected_spec_text).to  include("/etc/demo/secret")
      expect(mod.init_start).to           eq("systemctl start demo")
      expect(mod.init_stop).to            eq("systemctl stop demo")
      expect(mod.init_restart).to         eq("systemctl reload demo")
      expect(mod.reboot_required).to      be false
      expect(mod.description).to          eq("Demo manifest for import-service tests.")
    end

    it "stores the raw yaml on manifest_yaml" do
      described_class.import!(node_module: mod, yaml: manifest_yaml)
      expect(mod.reload.manifest_yaml).to eq(manifest_yaml)
    end

    it "preserves security + skills + build hints under config" do
      described_class.import!(node_module: mod, yaml: manifest_yaml)
      mod.reload
      expect(mod.config["security"]).to include("capabilities" => [ "CAP_NET_BIND_SERVICE" ])
      expect(mod.config["build"]).to include("apt_snapshot" => "20260415T000000Z")
      expect(mod.config["display_name"]).to eq("Demo Module")
      expect(mod.config["license"]).to eq("MIT")
    end

    it "preserves unknown top-level keys under config.manifest_extras" do
      yaml = manifest_yaml + "\nfuture_field: experimental_value\n"
      described_class.import!(node_module: mod, yaml: yaml)
      expect(mod.reload.config["manifest_extras"]).to eq("future_field" => "experimental_value")
    end

    it "creates a NodeModuleVersion when create_version: true" do
      result = described_class.import!(node_module: mod, yaml: manifest_yaml,
                                       create_version: true,
                                       version_changelog: "Initial import")
      expect(result.ok?).to be true
      version = result.node_module_version
      expect(version).to be_a(System::NodeModuleVersion)
      expect(version.version_number).to eq(1)
      expect(version.changelog).to eq("Initial import")
      expect(version.promotion_state).to eq("built")
      # Spec arrays on the version are base64-encoded
      decoded = version.protected_spec.map { |e| Base64.decode64(e) }
      expect(decoded).to include("/etc/demo/secret")
      expect(mod.reload.current_version).to eq(version)
    end

    it "skips version creation by default" do
      result = described_class.import!(node_module: mod, yaml: manifest_yaml)
      expect(result.ok?).to be true
      expect(result.node_module_version).to be_nil
      expect(mod.reload.versions.count).to eq(0)
    end

    context "validation" do
      it "rejects unsupported schema_version" do
        bad = manifest_yaml.sub("schema_version: 1", "schema_version: 99")
        result = described_class.import!(node_module: mod, yaml: bad)
        expect(result.ok?).to be false
        expect(result.error).to include("manifest validation failed")
        expect(result.validation_errors.join).to include("schema_version")
      end

      it "rejects a manifest whose name doesn't match the module" do
        bad = manifest_yaml.sub("name: demo-mod", "name: wrong-name")
        result = described_class.import!(node_module: mod, yaml: bad)
        expect(result.ok?).to be false
        expect(result.validation_errors.join).to include("does not match")
      end

      it "rejects spec fields that aren't string arrays" do
        bad = manifest_yaml.sub("mask:\n  - \"/var/cache/apt/**\"", "mask: not_an_array")
        result = described_class.import!(node_module: mod, yaml: bad)
        expect(result.ok?).to be false
        expect(result.validation_errors.join).to include("mask must be an array of strings")
      end

      it "rejects malformed yaml" do
        result = described_class.import!(node_module: mod, yaml: "  : :: invalid\n  bad: [")
        expect(result.ok?).to be false
        expect(result.error).to include("manifest YAML parse failed")
      end

      it "rejects blank yaml" do
        result = described_class.import!(node_module: mod, yaml: "")
        expect(result.ok?).to be false
        expect(result.error).to include("yaml content is blank")
      end
    end

    context "dependency resolution" do
      let!(:base_module) do
        create(:system_node_module, account: account, node_platform: platform,
               category: category, name: "system-base")
      end

      it "creates ModuleDependency rows for deps that resolve by name" do
        yaml = manifest_yaml.sub(
          "requires: []",
          "requires: [\"powernode/system-base@^1.0\"]"
        )
        result = described_class.import!(node_module: mod, yaml: yaml)
        expect(result.ok?).to be true
        expect(result.resolved_dependencies.size).to eq(1)
        dep = result.resolved_dependencies.first
        expect(dep[:status]).to eq("resolved")
        expect(System::ModuleDependency.where(node_module: mod, dependency: base_module)).to exist
      end

      it "reports unresolved dependencies without failing the import" do
        yaml = manifest_yaml.sub(
          "requires: []",
          "requires: [\"powernode/not-yet-published@^1.0\"]"
        )
        result = described_class.import!(node_module: mod, yaml: yaml)
        expect(result.ok?).to be true
        expect(result.resolved_dependencies.first[:status]).to eq("unresolved")
      end
    end
  end
end
