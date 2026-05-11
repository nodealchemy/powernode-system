# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::TemplateExpansionService do
  let(:account) { create(:account) }
  let(:repo) { create(:system_package_repository, account: account) }

  # NOTE on naming: Account.after_create_commit seeds default modules
  # (system-base, security-hardening, chrony, apache, nginx, rpi4-firmware)
  # into every new account via AccountBootstrapService. To avoid collisions
  # we use a per-suite unique prefix that doesn't appear in those seeds.
  let(:suffix) { "tx#{SecureRandom.hex(3)}" }

  # Build a small fleet of NodeModules with a package origin so the
  # per-template recommends override logic has something to override.
  #   appx (top-level) → libfoo (requires) + ssl-helper (recommends default) +
  #                       net-helper (recommends default) + observer (recommends NOT in default)
  let(:nginx_mod)   { create(:system_node_module, account: account, name: "appx-#{suffix}", auto_generated: false) }
  let(:libc6_mod)   { create(:system_node_module, account: account, name: "ubuntu-noble--libfoo-#{suffix}", auto_generated: true) }
  let(:ssl_mod)     { create(:system_node_module, account: account, name: "ubuntu-noble--ssl-helper-#{suffix}", auto_generated: true) }
  let(:iproute_mod) { create(:system_node_module, account: account, name: "ubuntu-noble--net-helper-#{suffix}", auto_generated: true) }
  let(:monitor_mod) { create(:system_node_module, account: account, name: "ubuntu-noble--observer-#{suffix}", auto_generated: true) }

  before do
    # Wire dependencies on nginx
    create(:system_module_dependency, node_module: nginx_mod, dependency: libc6_mod,
                                       dependency_type: "requires", required: true)
    create(:system_module_dependency, node_module: nginx_mod, dependency: ssl_mod,
                                       dependency_type: "recommends", required: false)
    create(:system_module_dependency, node_module: nginx_mod, dependency: iproute_mod,
                                       dependency_type: "recommends", required: false)
    create(:system_module_dependency, node_module: nginx_mod, dependency: monitor_mod,
                                       dependency_type: "recommends", required: false)

    # nginx's PackageModuleLink encodes the DEFAULT recommends selection
    # (ssl-helper + net-helper picked at materialize time; observer not picked).
    # Each transitive module has a link too — needed for the predicate's
    # `to_module.package_module_link.package_name` lookup.
    create(:system_package_module_link, node_module: nginx_mod, package_repository: repo,
                                         package_name: "appx", auto_generated: false,
                                         recommends_chosen: %w[ssl-helper net-helper])
    create(:system_package_module_link, node_module: libc6_mod, package_repository: repo, package_name: "libfoo")
    create(:system_package_module_link, node_module: ssl_mod, package_repository: repo, package_name: "ssl-helper")
    create(:system_package_module_link, node_module: iproute_mod, package_repository: repo, package_name: "net-helper")
    create(:system_package_module_link, node_module: monitor_mod, package_repository: repo, package_name: "observer")
  end

  let(:template) { create(:system_node_template, account: account) }

  def template_modules_for(override:)
    tm = create(:system_template_module, node_template: template, node_module: nginx_mod,
                                          recommends_override: override)
    [tm]
  end

  describe "#expand" do
    it "case 1: inherits defaults when recommends_override is empty" do
      tms = template_modules_for(override: {})
      expansion = described_class.new(template_modules: tms).expand
      names = expansion.modules.map(&:name)
      # nginx (explicit) + libfoo (required) + ssl-helper + net-helper (recommends_chosen)
      # observer NOT included (not in defaults)
      expect(names).to include(nginx_mod.name, libc6_mod.name, ssl_mod.name, iproute_mod.name)
      expect(names).not_to include(monitor_mod.name)
    end

    it "case 2: `excluded` strips entries from the defaults" do
      tms = template_modules_for(override: { "excluded" => ["net-helper"] })
      expansion = described_class.new(template_modules: tms).expand
      names = expansion.modules.map(&:name)
      expect(names).to include(ssl_mod.name)
      expect(names).not_to include(iproute_mod.name)
    end

    it "case 3: `included` adds entries beyond the defaults" do
      tms = template_modules_for(override: { "included" => ["observer"] })
      expansion = described_class.new(template_modules: tms).expand
      names = expansion.modules.map(&:name)
      expect(names).to include(monitor_mod.name)
      # Defaults still flow through
      expect(names).to include(ssl_mod.name, iproute_mod.name)
    end

    it "case 4: `replace` ignores defaults entirely" do
      tms = template_modules_for(override: { "replace" => ["ssl-helper"] })
      expansion = described_class.new(template_modules: tms).expand
      names = expansion.modules.map(&:name)
      expect(names).to include(ssl_mod.name)
      expect(names).not_to include(iproute_mod.name, monitor_mod.name)
    end

    it "case 5: marks auto_resolved + populates source_template_module_for" do
      tms = template_modules_for(override: {})
      expansion = described_class.new(template_modules: tms).expand
      explicit_id = nginx_mod.id
      transitive_id = libc6_mod.id

      expect(expansion.auto_resolved_ids).not_to include(explicit_id)
      expect(expansion.auto_resolved_ids).to include(transitive_id)

      # Explicit module's source TM points at its own TemplateModule
      expect(expansion.source_template_module_for[explicit_id]&.id).to eq(tms.first.id)
      # Transitive deps are sourced back to the TM that pulled them in
      expect(expansion.source_template_module_for[transitive_id]&.id).to eq(tms.first.id)
    end
  end
end
