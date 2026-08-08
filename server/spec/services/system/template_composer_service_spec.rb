# frozen_string_literal: true

require "rails_helper"

# Direct unit coverage for the three TemplateComposerService surfaces that were
# previously exercised only through TemplateCompositionAnalysis verdicts and
# request specs (IMP-a1b0a9be4770): #detect_conflicts, #serialize_modules, and
# #footprint, plus the private paths_overlap? whose glob-stripping semantics
# had zero direct assertions anywhere in spec/. #dependency_graph keeps its own
# dedicated spec file.
RSpec.describe System::TemplateComposerService do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }

  def mod(name, variety: "subscription", category: self.category, **attrs)
    create(:system_node_module, account: account, node_platform: platform, category: category,
           variety: variety, name: "#{name}-#{SecureRandom.hex(3)}", **attrs)
  end

  def conflicts_dep(owner, other)
    ::System::ModuleDependency.create!(node_module: owner, dependency: other,
                                       dependency_type: "conflicts", required: false)
  end

  # Mirrors how callers hand modules over: eager-loaded closure.
  def service_for(modules)
    loaded = ::System::NodeModule.where(id: modules.map(&:id))
                                 .includes(:module_dependencies, :category, :current_version,
                                           :node_platform, :package_module_link)
    described_class.new(loaded)
  end

  def b64(*paths)
    paths.map { |p| Base64.strict_encode64(p) }
  end

  describe "#detect_conflicts" do
    it "reports a module_dependency_conflict when both sides of a Conflicts: relation are in the closure" do
      a = mod("apache")
      b = mod("nginx")
      conflicts_dep(a, b)

      conflicts = service_for([ a, b ]).detect_conflicts
      entry = conflicts.find { |c| c[:kind] == "module_dependency_conflict" }

      expect(entry).to include(severity: "error", source_id: a.id, target_id: b.id)
      expect(entry[:detail]).to include(a.name).and include(b.name)
    end

    it "ignores a Conflicts: relation whose target is outside the closure" do
      a = mod("apache")
      elsewhere = mod("nginx")
      conflicts_dep(a, elsewhere)

      expect(service_for([ a ]).detect_conflicts).to be_empty
    end

    it "reports an instance_variety_collision for two instance modules in one category" do
      first  = mod("inst-a", variety: "instance")
      second = mod("inst-b", variety: "instance")

      conflicts = service_for([ first, second ]).detect_conflicts
      entry = conflicts.find { |c| c[:kind] == "instance_variety_collision" }

      expect(entry).to include(severity: "error", category_id: category.id)
      expect(entry[:module_ids]).to match_array([ first.id, second.id ])
    end

    it "allows one instance module per category (no collision across categories)" do
      other_category = create(:system_node_module_category, account: account)
      a = mod("inst-a", variety: "instance")
      b = mod("inst-b", variety: "instance", category: other_category)

      expect(service_for([ a, b ]).detect_conflicts).to be_empty
    end

    it "reports a protected_spec_overlap warning naming ONLY the overlapping claims" do
      claimer = mod("guardian", protected_spec: b64("/opt/shared/**", "/etc/guardian/**"))
      other   = mod("writer",   file_spec: b64("/opt/shared/bin/*"))

      conflicts = service_for([ claimer, other ]).detect_conflicts
      entry = conflicts.find { |c| c[:kind] == "protected_spec_overlap" }

      expect(entry).to include(severity: "warning",
                               claimer_id: claimer.id, other_id: other.id)
      expect(entry[:paths]).to eq([ "/opt/shared/**" ]) # not the untouched /etc claim
      expect(entry[:detail]).to include(claimer.name).and include(other.name)
    end

    it "does not report protected_spec_overlap for disjoint path trees" do
      claimer = mod("guardian", protected_spec: b64("/opt/shared/**"))
      other   = mod("writer",   file_spec: b64("/var/log/app/**"))

      expect(service_for([ claimer, other ]).detect_conflicts).to be_empty
    end
  end

  describe "#serialize_modules" do
    it "flags the operator's explicit picks and marks the rest auto_resolved" do
      picked = mod("picked")
      pulled = mod("pulled")

      rows = service_for([ picked, pulled ]).serialize_modules(explicit_ids: [ picked.id ])
      by_id = rows.index_by { |r| r[:id] }

      expect(by_id[picked.id][:auto_resolved]).to be(false)
      expect(by_id[pulled.id][:auto_resolved]).to be(true)
    end

    it "carries package provenance when a PackageModuleLink exists, nil otherwise" do
      linked = mod("pkg-driven")
      link = create(:system_package_module_link, node_module: linked)
      plain = mod("hand-authored")

      rows = service_for([ linked, plain ]).serialize_modules(explicit_ids: [])
      by_id = rows.index_by { |r| r[:id] }

      expect(by_id[linked.id][:package_source]).to eq(
        repository_id: link.package_repository_id, package_name: link.package_name,
        package_version: link.package_version, architecture: link.architecture
      )
      expect(by_id[plain.id][:package_source]).to be_nil
    end

    it "serializes the current version compactly (nil when the module has none)" do
      bare = mod("unversioned")

      row = service_for([ bare ]).serialize_modules(explicit_ids: []).first

      expect(row[:current_version]).to be_nil
      expect(row).to include(name: bare.name, variety: bare.variety, category_id: category.id)
    end

    it "serializes the current version's id, number, and digest when one exists" do
      versioned = mod("versioned")
      version = create(:system_node_module_version, node_module: versioned)
      versioned.update!(current_version: version)

      row = service_for([ versioned ]).serialize_modules(explicit_ids: []).first

      expect(row[:current_version]).to eq(
        id: version.id, version_number: version.version_number,
        oci_digest: version.try(:oci_digest)
      )
    end
  end

  describe "#footprint" do
    it "counts modules, sums package_spec entries, and dedups architectures" do
      a = mod("a", package_spec: %w[curl jq])
      b = mod("b", package_spec: %w[htop])
      c = mod("c") # factory default {} → zero packages

      fp = service_for([ a, b, c ]).footprint

      expect(fp[:module_count]).to eq(3)
      expect(fp[:estimated_package_count]).to eq(3)
      expect(fp[:architectures]).to eq([ platform.node_architecture.name ])
    end

    it "drops modules without a platform from architectures (node_platform is optional)" do
      with_arch = mod("archful")
      floating  = create(:system_node_module, account: account, node_platform: nil,
                         category: category, name: "floating-#{SecureRandom.hex(3)}")

      fp = service_for([ with_arch, floating ]).footprint

      expect(fp[:module_count]).to eq(2)
      expect(fp[:architectures]).to eq([ platform.node_architecture.name ])
    end
  end

  describe "#paths_overlap? (private — the preview's cheap prefix check)" do
    subject(:service) { described_class.new([]) }

    def overlap?(a, b)
      service.send(:paths_overlap?, a, b)
    end

    it "matches identical paths and glob-stripped equivalents" do
      expect(overlap?("/etc/app", "/etc/app")).to be(true)
      expect(overlap?("/etc/app/**", "/etc/app")).to be(true)
      expect(overlap?("/etc/app/*", "/etc/app")).to be(true)
    end

    it "matches prefix containment in either direction" do
      expect(overlap?("/etc/app", "/etc/app/conf.d/site.conf")).to be(true)
      expect(overlap?("/etc/app/conf.d/site.conf", "/etc/app")).to be(true)
      expect(overlap?("/etc/app/**", "/etc/app/conf.d")).to be(true)
    end

    it "does not treat a shared string prefix as containment (needs a path separator)" do
      expect(overlap?("/etc/app", "/etc/application")).to be(false)
      expect(overlap?("/opt/app2", "/opt/app")).to be(false)
    end

    it "does not match disjoint trees" do
      expect(overlap?("/etc/app/**", "/var/log/**")).to be(false)
    end
  end
end
