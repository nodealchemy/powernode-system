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
      users:
        - name: powernode
        - name: postgres
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

    it "does NOT trigger NodeModule#auto_create_version on the spec write (suppresses the after_update callback)" do
      # Pre-existing version so versioned? returns true; without the
      # suppression in ManifestImportService, the file_spec write would
      # trip auto_create_version and create a second (empty-artifact)
      # row.
      mod.create_version!(changelog: "v1")
      expect(mod.versions.count).to eq(1)

      result = described_class.import!(node_module: mod, yaml: manifest_yaml)
      expect(result.ok?).to be true
      expect(mod.reload.versions.count).to eq(1)
    end

    it "still creates a version row when create_version: true is passed (caller's explicit snapshot path)" do
      result = described_class.import!(
        node_module: mod, yaml: manifest_yaml,
        create_version: true, version_changelog: "explicit snapshot"
      )
      expect(result.ok?).to be true
      expect(result.node_module_version).to be_present
      expect(mod.reload.versions.count).to eq(1)
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
      # System::AccountBootstrapService auto-creates "system-base" in
      # every new account via Account.after_create_commit, so we look
      # it up rather than recreate (would hit uniqueness validation).
      let!(:base_module) do
        ::System::NodeModule.find_or_create_by!(account: account, name: "system-base") do |m|
          m.node_platform = platform
          m.category      = category
          m.variety       = "subscription"
        end
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
        expect(rails.service_user.username).to eq("powernode")
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
              user: powernode
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

      it "rejects a service missing both start_command and unit_body" do
        bad = manifest_yaml + <<~YAML
          services:
            - { name: rails }
        YAML
        result = described_class.import!(node_module: mod, yaml: bad)
        expect(result.ok?).to be false
        expect(result.validation_errors.join).to include("start_command or services[0].unit_body is required")
      end

      it "rejects a service declaring both start_command and unit_body" do
        bad = manifest_yaml + <<~YAML
          services:
            - name: rails
              start_command: "x"
              unit_body: |
                [Unit]
                Description=x
                [Service]
                ExecStart=/bin/true
                [Install]
                WantedBy=multi-user.target
        YAML
        result = described_class.import!(node_module: mod, yaml: bad)
        expect(result.ok?).to be false
        expect(result.validation_errors.join).to include("mutually exclusive")
      end

      it "rejects a unit_body missing [Service] or WantedBy=" do
        bad = manifest_yaml + <<~YAML
          services:
            - name: rails
              unit_body: |
                [Unit]
                Description=x
                [Service]
                ExecStart=/bin/true
        YAML
        result = described_class.import!(node_module: mod, yaml: bad)
        expect(result.ok?).to be false
        expect(result.validation_errors.join).to include("[Service] section and a WantedBy= line")
      end

      it "creates a ModuleService from a unit_body service without requiring user:" do
        with_body = manifest_yaml + <<~YAML
          services:
            - name: claude
              unit_body: |
                [Unit]
                Description=Claude tmux session
                After=network-online.target
                Wants=network-online.target

                [Service]
                Type=oneshot
                RemainAfterExit=yes
                User=pnadmin
                ExecStart=/usr/local/bin/claude-tmux-start.sh

                [Install]
                WantedBy=multi-user.target
        YAML
        result = described_class.import!(node_module: mod, yaml: with_body)
        expect(result.ok?).to be true
        claude = mod.reload.module_services.find_by(name: "claude")
        expect(claude.start_command).to be_nil
        expect(claude.unit_body).to include("Type=oneshot")
        expect(claude.service_user).to be_nil
        expect(claude.system_user).to be_nil
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
              user: powernode
              dependencies:
                - { service: ghost, kind: requires_health }
        YAML
        result = described_class.import!(node_module: mod, yaml: bad)
        expect(result.ok?).to be false
        expect(result.error).to include("references unknown service")
      end
    end

    context "identity parsing (users / groups / sudoers)" do
      before do
        ::System::ModuleUserDeclaration.delete_all
        ::System::ServiceUserGroupMembership.delete_all
        ::System::ServiceUser.delete_all
        ::System::ServiceGroup.delete_all
      end

      let(:identity_yaml) do
        manifest_yaml + <<~YAML
          groups:
            - name: ssl-cert
          sudoers:
            - id: reload
              user: postgres
              runas: root
              commands:
                - /usr/bin/systemctl reload postgresql.service
        YAML
      end

      it "allocates ServiceUser + ServiceGroup rows for each declared identity" do
        result = described_class.import!(node_module: mod, yaml: identity_yaml)
        expect(result.ok?).to be true
        # manifest_yaml declares powernode + postgres; identity_yaml adds ssl-cert.
        # Each user gets an auto-allocated same-name primary group, so we expect 3 groups
        # (postgres, powernode, ssl-cert) and 2 users (postgres, powernode).
        expect(::System::ServiceUser.pluck(:username)).to contain_exactly("postgres", "powernode")
        expect(::System::ServiceGroup.pluck(:groupname))
          .to contain_exactly("postgres", "powernode", "ssl-cert")
      end

      it "creates one ModuleUserDeclaration per declared user + per declared/auto-allocated group" do
        described_class.import!(node_module: mod, yaml: identity_yaml)
        decls = mod.reload.module_user_declarations
        # 2 user declarations: postgres + powernode.
        expect(decls.where.not(service_user_id: nil).count).to eq(2)
        # 3 group declarations: ssl-cert (explicit) + postgres + powernode
        # (auto-allocated same-name primary groups). The auto-allocated
        # ones ALSO get declarations so they drain when the user does.
        expect(decls.where.not(service_group_id: nil).count).to eq(3)
      end

      it "creates SudoersGrant rows from the sudoers: block" do
        described_class.import!(node_module: mod, yaml: identity_yaml)
        grant = mod.reload.sudoers_grants.find_by(grant_id: "reload")
        expect(grant).to be_present
        expect(grant.service_user.username).to eq("postgres")
        expect(grant.runas_user).to eq("root")
        expect(grant.commands).to eq([ "/usr/bin/systemctl reload postgresql.service" ])
      end

      it "is idempotent — re-importing reuses identity rows by name" do
        described_class.import!(node_module: mod, yaml: identity_yaml)
        users_before = ::System::ServiceUser.pluck(:id).sort
        described_class.import!(node_module: mod, yaml: identity_yaml)
        expect(::System::ServiceUser.pluck(:id).sort).to eq(users_before)
      end

      it "drains an identity when no module declaration still references it" do
        described_class.import!(node_module: mod, yaml: identity_yaml)
        described_class.import!(node_module: mod, yaml: manifest_yaml)
        # manifest_yaml has no groups: block, so ssl-cert's only declarer
        # disappears -> it transitions to draining (kept for 24h reaper).
        ssl = ::System::ServiceGroup.find_by(groupname: "ssl-cert")
        expect(ssl.state).to eq("draining")
      end

      it "destroys sudoers grants immediately (no drain) on re-import without them" do
        described_class.import!(node_module: mod, yaml: identity_yaml)
        expect(mod.reload.sudoers_grants.count).to eq(1)
        described_class.import!(node_module: mod, yaml: manifest_yaml)
        expect(mod.reload.sudoers_grants.count).to eq(0)
      end

      it "rejects a sudoers grant with a non-absolute command path" do
        bad = manifest_yaml + <<~YAML
          sudoers:
            - id: bad
              user: postgres
              commands: [systemctl reload postgres]
        YAML
        result = described_class.import!(node_module: mod, yaml: bad)
        expect(result.ok?).to be false
        expect(result.validation_errors.join).to include("must be an absolute path")
      end

      it "rejects a sudoers grant containing the literal ALL token" do
        bad = manifest_yaml + <<~YAML
          sudoers:
            - id: bad
              user: postgres
              commands: ["/bin/foo ALL"]
        YAML
        result = described_class.import!(node_module: mod, yaml: bad)
        expect(result.ok?).to be false
        expect(result.validation_errors.join).to include("ALL")
      end

      it "rejects a user name that doesn't match the POSIX format regex" do
        bad = manifest_yaml + <<~YAML
          users:
            - name: BadName
        YAML
        result = described_class.import!(node_module: mod, yaml: bad)
        expect(result.ok?).to be false
        expect(result.validation_errors.join).to match(/users\[\d+\]\.name/)
      end

      context "home-path lints (module import safety)" do
        it "rejects a file_spec entry that ships a path under /home" do
          bad = manifest_yaml.sub(
            "file_spec:\n  - \"/etc/demo/**\"",
            "file_spec:\n  - \"/home/**\"\n  - \"/etc/demo/**\""
          )
          result = described_class.import!(node_module: mod, yaml: bad)
          expect(result.ok?).to be false
          expect(result.validation_errors.join).to include("ships a path under /home")
        end

        it "rejects a file_spec entry pointing at a specific file under /home" do
          bad = manifest_yaml.sub(
            "file_spec:\n  - \"/etc/demo/**\"",
            "file_spec:\n  - \"/home/pnadmin/.bashrc\"\n  - \"/etc/demo/**\""
          )
          result = described_class.import!(node_module: mod, yaml: bad)
          expect(result.ok?).to be false
          expect(result.validation_errors.join).to include("ships a path under /home")
        end

        it "does not flag file_spec entries that merely contain the substring 'home' elsewhere in the path" do
          ok = manifest_yaml.sub(
            "file_spec:\n  - \"/etc/demo/**\"",
            "file_spec:\n  - \"/opt/somehome/**\"\n  - \"/etc/demo/**\""
          )
          result = described_class.import!(node_module: mod, yaml: ok)
          expect(result.ok?).to be true
        end

        it "rejects users[].home outside the allowed managed roots (e.g. /etc)" do
          bad = manifest_yaml + <<~YAML
            users:
              - name: extra-svc
                home: /etc/extra-svc
          YAML
          result = described_class.import!(node_module: mod, yaml: bad)
          expect(result.ok?).to be false
          expect(result.validation_errors.join).to include("is not under an allowed home root")
        end

        it "accepts users[].home under an allowed managed root (/var/lib)" do
          ok = manifest_yaml + <<~YAML
            users:
              - name: extra-svc
                home: /var/lib/extra-svc
          YAML
          result = described_class.import!(node_module: mod, yaml: ok)
          expect(result.ok?).to be true
        end

        it "accepts users[].home under /home for a human-login-style account" do
          ok = manifest_yaml + <<~YAML
            users:
              - name: extra-human
                home: /home/extra-human
          YAML
          result = described_class.import!(node_module: mod, yaml: ok)
          expect(result.ok?).to be true
        end

        it "accepts a manifest with no explicit home (UserAllocator's /var/lib/<name> default)" do
          result = described_class.import!(node_module: mod, yaml: manifest_yaml)
          expect(result.ok?).to be true
        end
      end
    end
  end

  describe "capability handling" do
    # Helper: build a NodeModule with the given provides[] tags via a
    # minimal manifest. Reuses the platform + category + account fixtures.
    def import_with_provides(name, provides)
      target = create(:system_node_module, account: account, node_platform: platform,
                      category: category, variety: "subscription", name: name)
      yaml = <<~YAML
        schema_version: 1
        name: #{name}
        display_name: "Test"
        description: "Capability fixture."
        license: "MIT"
        dependencies:
          requires: []
          provides:
        #{provides.map { |p| "    - #{p}" }.join("\n")}
      YAML
      described_class.import!(node_module: target, yaml: yaml)
      target.reload
    end

    def import_with_requires(name, requires)
      target = create(:system_node_module, account: account, node_platform: platform,
                      category: category, variety: "subscription", name: name)
      yaml = <<~YAML
        schema_version: 1
        name: #{name}
        display_name: "Test consumer"
        description: "Requires fixture."
        license: "MIT"
        dependencies:
          requires:
        #{requires.map { |r| "    - #{r}" }.join("\n")}
          provides: []
      YAML
      [ target, described_class.import!(node_module: target, yaml: yaml) ]
    end

    describe "denormalizes provides[] into the capabilities column" do
      it "stores bare and versioned tags as the JSONB array" do
        provider = import_with_provides("provider-1",
                                        %w[database.postgres database.postgres.primary database.postgres@16])
        expect(provider.capabilities).to eq(%w[database.postgres database.postgres.primary database.postgres@16])
      end

      it "stores [] when provides is absent or empty" do
        provider = import_with_provides("provider-empty", [])
        expect(provider.capabilities).to eq([])
      end

      it "drops empty-string entries defensively" do
        # Synthesize a manifest with a stray empty provides entry (operators
        # sometimes leave `- ""` from YAML editing accidents).
        target = create(:system_node_module, account: account, node_platform: platform,
                        category: category, variety: "subscription", name: "provider-stray")
        yaml = <<~YAML
          schema_version: 1
          name: provider-stray
          display_name: "T"
          description: "stray empty entry"
          license: "MIT"
          dependencies:
            requires: []
            provides:
              - cache.redis
              - ""
        YAML
        described_class.import!(node_module: target, yaml: yaml)
        target.reload
        expect(target.capabilities).to eq([ "cache.redis" ])
      end
    end

    describe "resolve_dependencies with capability: syntax" do
      it "resolves capability:<tag> to the matching provider's module" do
        provider = import_with_provides("postgres-host", %w[database.postgres])
        _consumer, result = import_with_requires("hub-app", [ "capability:database.postgres" ])

        resolved = result.resolved_dependencies.first
        expect(resolved[:status]).to eq("resolved")
        expect(resolved[:capability]).to eq("database.postgres")
        expect(resolved[:dependency_id]).to eq(provider.id)
      end

      it "respects version constraint against versioned provides" do
        old_pg = import_with_provides("pg-15", %w[database.postgres@15])
        new_pg = import_with_provides("pg-16", %w[database.postgres@16])

        _consumer, result = import_with_requires("hub-app", [ "capability:database.postgres@>=16" ])

        resolved = result.resolved_dependencies.first
        expect(resolved[:status]).to eq("resolved")
        expect(resolved[:dependency_id]).to eq(new_pg.id)
        expect(resolved[:dependency_id]).not_to eq(old_pg.id)
      end

      it "bare tag does NOT satisfy a versioned constraint" do
        bare_only = import_with_provides("pg-bare", %w[database.postgres])
        _consumer, result = import_with_requires("hub-app", [ "capability:database.postgres@>=16" ])

        resolved = result.resolved_dependencies.first
        expect(resolved[:status]).to eq("unresolved")
        expect(bare_only).not_to be_nil # silence unused-variable warning
      end

      it "picks highest-priority provider when multiple satisfy" do
        low = import_with_provides("redis-low",  %w[cache.redis])
        low.update!(priority: 10)
        high = import_with_provides("redis-high", %w[cache.redis])
        high.update!(priority: 100)

        _consumer, result = import_with_requires("hub-app", [ "capability:cache.redis" ])

        resolved = result.resolved_dependencies.first
        expect(resolved[:status]).to eq("resolved")
        expect(resolved[:dependency_id]).to eq(high.id)
      end

      it "returns status=unresolved when no provider matches" do
        _consumer, result = import_with_requires("hub-app", [ "capability:storage.nonexistent" ])
        resolved = result.resolved_dependencies.first
        expect(resolved[:status]).to eq("unresolved")
        expect(resolved[:capability]).to eq("storage.nonexistent")
      end

      it "logs + returns nil-target on invalid version constraint" do
        import_with_provides("pg-16", %w[database.postgres@16])
        allow(Rails.logger).to receive(:warn)

        _consumer, result = import_with_requires("hub-app", [ "capability:database.postgres@!!!bogus" ])
        resolved = result.resolved_dependencies.first
        expect(resolved[:status]).to eq("unresolved")
        expect(Rails.logger).to have_received(:warn).with(/invalid version constraint/)
      end

      it "ignores the consumer module itself even if it provides the capability" do
        # Edge case: a module shouldn't resolve a capability requirement
        # by pointing at itself.
        target = create(:system_node_module, account: account, node_platform: platform,
                        category: category, variety: "subscription", name: "self-ref")
        yaml = <<~YAML
          schema_version: 1
          name: self-ref
          display_name: "T"
          description: "self-reference test"
          license: "MIT"
          dependencies:
            requires:
              - capability:db.foo
            provides:
              - db.foo
        YAML
        result = described_class.import!(node_module: target, yaml: yaml)
        resolved = result.resolved_dependencies.first
        expect(resolved[:status]).to eq("unresolved")
      end
    end

    describe "name-based + capability-based mixed in same requires:" do
      it "resolves each entry independently" do
        named  = create(:system_node_module, account: account, node_platform: platform,
                        category: category, variety: "subscription", name: "explicit-pin")
        capped = import_with_provides("redis-cap", %w[cache.redis])

        _consumer, result = import_with_requires("mixed-consumer",
                                                  [ "explicit-pin", "capability:cache.redis" ])

        statuses = result.resolved_dependencies.map { |r| r[:status] }
        expect(statuses).to all(eq("resolved"))
        ids = result.resolved_dependencies.map { |r| r[:dependency_id] }
        expect(ids).to contain_exactly(named.id, capped.id)
      end
    end
  end
end
