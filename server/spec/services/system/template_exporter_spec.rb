# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::TemplateExporter do
  let(:account) { create(:account) }
  let(:platform) { create(:system_node_platform, name: "Ubuntu 24.04") }
  let(:template) do
    create(:system_node_template,
      account: account,
      node_platform: platform,
      name: "Web App Template",
      description: "Template for web app instances",
      admin_user: "ubuntu",
      config: { "boot_timeout" => 60 }
    )
  end

  describe ".export" do
    context "with no module assignments" do
      it "returns ok with a complete bundle" do
        result = described_class.export(template: template)

        expect(result).to be_success
        bundle = result.data[:bundle]

        expect(bundle[:format_version]).to eq("1.0")
        expect(bundle[:kind]).to eq("system.node_template")
        expect(bundle[:exported_at]).to match(/\A\d{4}-\d{2}-\d{2}T/)
        expect(bundle[:template]).to include(
          name: "Web App Template",
          description: "Template for web app instances",
          admin_user: "ubuntu",
          config: { "boot_timeout" => 60 }
        )
        expect(bundle[:platform]).to include(name: "Ubuntu 24.04")
        expect(bundle[:modules]).to eq([])
      end

      it "produces a sluggified filename hint" do
        result = described_class.export(template: template)
        expect(result.data[:filename]).to match(/\Asystem-template-web-app-template-\d{14}\.json\z/)
      end
    end

    context "with module assignments" do
      let(:module_a) { create(:system_node_module, account: account, name: "nginx", variety: "config") }
      let(:module_b) { create(:system_node_module, account: account, name: "monitoring", variety: "instance") }

      before do
        create(:system_template_module, node_template: template, node_module: module_a, priority: 100, enabled: true)
        create(:system_template_module, node_template: template, node_module: module_b, priority: 50, enabled: false, config: { "metric" => "cpu" })
      end

      it "lists modules in priority-descending order" do
        result = described_class.export(template: template)
        names = result.data[:bundle][:modules].map { |m| m[:module_name] }
        expect(names).to eq(%w[nginx monitoring])
      end

      it "includes per-assignment overrides and enablement flags" do
        result = described_class.export(template: template)
        modules = result.data[:bundle][:modules]

        expect(modules.first).to include(
          module_name: "nginx",
          module_variety: "config",
          priority: 100,
          enabled: true
        )
        expect(modules.second).to include(
          module_name: "monitoring",
          priority: 50,
          enabled: false,
          config: { "metric" => "cpu" }
        )
      end
    end

    context "when the platform association resolves to nil" do
      # The schema requires node_platform_id, so this is an in-memory edge case
      # (e.g., the platform was deleted between query and serialization). The
      # exporter should still produce a valid bundle with platform: nil.
      it "produces a bundle with platform: nil rather than crashing" do
        allow(template).to receive(:node_platform).and_return(nil)

        result = described_class.export(template: template)
        expect(result).to be_success
        expect(result.data[:bundle][:platform]).to be_nil
      end
    end

    context "with invalid input" do
      it "raises ArgumentError when template is nil" do
        expect { described_class.export(template: nil) }.to raise_error(ArgumentError, /required/)
      end

      it "raises ArgumentError when template is the wrong class" do
        expect { described_class.export(template: account) }.to raise_error(ArgumentError, /must be a System::NodeTemplate/)
      end
    end
  end
end
