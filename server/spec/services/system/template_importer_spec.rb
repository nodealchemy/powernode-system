# frozen_string_literal: true

require "rails_helper"

# TemplateImporter materializes a whole template's joins from a bundle in one
# transaction, bypassing the assignment-path guard entirely. Like the clone it
# REPRODUCES a template authored elsewhere — refusing would make an
# export/import round trip lossy, and the bundle format has no way to say
# "this collision is deliberate" — so it warns via the Result it already
# carries rather than blocking.
RSpec.describe System::TemplateImporter do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account, name: "cat-#{SecureRandom.hex(3)}") }

  def node_module(name, variety: "subscription", in_category: category)
    create(:system_node_module, account: account, node_platform: platform,
           category: in_category, variety: variety, name: "#{name}-#{SecureRandom.hex(3)}")
  end

  def bundle_for(modules)
    {
      format_version: described_class::SUPPORTED_FORMAT_VERSIONS.first,
      kind: described_class::SUPPORTED_KIND,
      template: { name: "imported-#{SecureRandom.hex(3)}", description: "d", enabled: true },
      platform: { name: platform.name },
      modules: modules.map do |m|
        { module_name: m.name, module_variety: m.variety, priority: 50, enabled: true, config: {} }
      end
    }
  end

  subject(:importer) { described_class.new(account) }

  describe "#import!" do
    it "creates the template and its joins" do
      result = importer.import!(bundle: bundle_for([ node_module("solo") ]))

      expect(result).to be_ok
      expect(result.template_modules_count).to eq(1)
      expect(result.warnings).to be_empty
    end

    context "when the bundle composes badly" do
      let(:first)  { node_module("inst-a", variety: "instance") }
      let(:second) { node_module("inst-b", variety: "instance") }

      it "still imports — a round trip must not become lossy" do
        result = importer.import!(bundle: bundle_for([ first, second ]))

        expect(result).to be_ok
        expect(result.template_modules_count).to eq(2)
      end

      it "surfaces the conflict in the Result's warnings, naming the modules" do
        result = importer.import!(bundle: bundle_for([ first, second ]))

        expect(result.warnings.join(" ")).to include("instance_variety_collision")
          .and include(first.name).and include(second.name)
      end
    end

    it "warns about nothing when a disabled join is the only would-be collision" do
      bundle = bundle_for([ node_module("live-inst", variety: "instance"),
                            node_module("dark-inst", variety: "instance") ])
      bundle[:modules][1][:enabled] = false

      result = importer.import!(bundle: bundle)

      expect(result).to be_ok
      expect(result.warnings).to be_empty
    end

    it "leaves the existing refusal paths alone" do
      bundle = bundle_for([])
      bundle[:modules] = [ { module_name: "nope", module_variety: "config" } ]

      result = importer.import!(bundle: bundle)

      expect(result).not_to be_ok
      expect(result.missing_modules).to eq([ { name: "nope", variety: "config" } ])
    end
  end
end
