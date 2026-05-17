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

    context "services parsing (Decentralized Federation plan §A)" do
      let(:services_yaml_fragment) do
        <<~YAML
          services:
            - name: rails
              start_command: "bundle exec puma -C config/puma.rb"
              restart_policy: always
              user: powernode
              working_directory: /opt/powernode-rails
              env:
                RAILS_ENV: production
              exposed_ports:
                - { port: 3000, protocol: tcp, name: http }
              capabilities: []
              health:
                endpoint: /up
                method: GET
                interval_seconds: 30
                timeout_seconds: 5
                initial_delay_seconds: 10
              dependencies:
                - { service: postgres, kind: requires_health }
            - name: postgres
              start_command: "/usr/lib/postgresql/16/bin/postgres -D /var/lib/postgresql/16/main"
              restart_policy: always
              user: postgres
              exposed_ports:
                - { port: 5432, protocol: tcp, name: postgres }
        YAML
      end
      let(:yaml_with_services) { manifest_yaml + services_yaml_fragment }

      it "creates ModuleService rows from manifest.services" do
        result = described_class.import!(node_module: mod, yaml: yaml_with_services)
        expect(result.ok?).to be true
        mod.reload
        expect(mod.module_services.pluck(:name)).to match_array(%w[rails postgres])
        rails = mod.module_services.find_by(name: "rails")
        expect(rails.start_command).to eq("bundle exec puma -C config/puma.rb")
        expect(rails.restart_policy).to eq("always")
        expect(rails.run_as_user).to eq("powernode")
        expect(rails.exposed_ports).to eq([ { "port" => 3000, "protocol" => "tcp", "name" => "http" } ])
        expect(rails.health_endpoint).to eq("/up")
        expect(rails.health_interval_seconds).to eq(30)
      end

      it "creates cross-service ModuleServiceDependency edges within the manifest" do
        described_class.import!(node_module: mod, yaml: yaml_with_services)
        rails = mod.reload.module_services.find_by(name: "rails")
        postgres = mod.module_services.find_by(name: "postgres")
        expect(rails.outgoing_dependencies.count).to eq(1)
        edge = rails.outgoing_dependencies.first
        expect(edge.depends_on_module_service).to eq(postgres)
        expect(edge.kind).to eq("requires_health")
      end

      it "is idempotent: re-importing the same manifest doesn't churn" do
        described_class.import!(node_module: mod, yaml: yaml_with_services)
        original_ids = mod.reload.module_services.pluck(:id)
        described_class.import!(node_module: mod, yaml: yaml_with_services)
        expect(mod.reload.module_services.pluck(:id)).to match_array(original_ids)
      end

      it "deletes services declared previously but absent from a re-import" do
        described_class.import!(node_module: mod, yaml: yaml_with_services)
        expect(mod.reload.module_services.pluck(:name)).to include("postgres")

        rails_only = manifest_yaml + <<~YAML
          services:
            - name: rails
              start_command: "bundle exec puma -C config/puma.rb"
              restart_policy: always
        YAML
        described_class.import!(node_module: mod, yaml: rails_only)
        expect(mod.reload.module_services.pluck(:name)).to eq([ "rails" ])
      end

      it "deletes all services when re-imported without a services key" do
        described_class.import!(node_module: mod, yaml: yaml_with_services)
        expect(mod.reload.module_services.count).to eq(2)
        described_class.import!(node_module: mod, yaml: manifest_yaml)
        expect(mod.reload.module_services.count).to eq(0)
      end

      it "rejects a manifest with a duplicate service name" do
        dup = manifest_yaml + <<~YAML
          services:
            - { name: rails, start_command: "x" }
            - { name: rails, start_command: "y" }
        YAML
        result = described_class.import!(node_module: mod, yaml: dup)
        expect(result.ok?).to be false
        expect(result.validation_errors.join).to include("duplicates an earlier service")
      end

      it "rejects a service missing start_command" do
        bad = manifest_yaml + <<~YAML
          services:
            - { name: rails }
        YAML
        result = described_class.import!(node_module: mod, yaml: bad)
        expect(result.ok?).to be false
        expect(result.validation_errors.join).to include("start_command is required")
      end

      it "rejects a service with invalid restart_policy" do
        bad = manifest_yaml + <<~YAML
          services:
            - { name: rails, start_command: "x", restart_policy: bogus }
        YAML
        result = described_class.import!(node_module: mod, yaml: bad)
        expect(result.ok?).to be false
        expect(result.validation_errors.join).to include("restart_policy must be one of")
      end

      it "rejects a dependency referencing a non-existent service in the manifest" do
        bad = manifest_yaml + <<~YAML
          services:
            - name: rails
              start_command: "x"
              dependencies:
                - { service: ghost, kind: requires_health }
        YAML
        result = described_class.import!(node_module: mod, yaml: bad)
        expect(result.ok?).to be false
        expect(result.error).to include("references unknown service")
      end
    end
  end
end
