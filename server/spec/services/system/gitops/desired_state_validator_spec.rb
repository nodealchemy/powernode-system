# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::Gitops::DesiredStateValidator do
  describe ".call" do
    it "accepts a minimal valid fleet.yaml" do
      raw = { "templates" => { "default" => { "description" => "base" } } }
      result = described_class.call(raw)
      expect(result.ok?).to be true
      expect(result.errors).to be_empty
    end

    it "accepts an empty hash (no sections is valid)" do
      result = described_class.call({})
      expect(result.ok?).to be true
    end

    it "rejects unknown top-level keys (catches typos like 'tempaltes')" do
      result = described_class.call({ "tempaltes" => {} })
      expect(result.ok?).to be false
      expect(result.errors["tempaltes"]).to include(/unknown top-level key/)
    end

    it "rejects non-string template fields like node_platform: 42" do
      raw = { "templates" => { "foo" => { "node_platform" => 42 } } }
      result = described_class.call(raw)
      expect(result.ok?).to be false
      expect(result.errors["templates.foo.node_platform"]).to include(/must be a string/)
    end

    it "rejects assignment keys without colon" do
      raw = { "assignments" => { "bad-key-no-colon" => { "enabled" => true } } }
      result = described_class.call(raw)
      expect(result.ok?).to be false
      expect(result.errors["assignments.bad-key-no-colon"]).to include(/'node-name:module-name'/)
    end

    it "rejects non-boolean assignment.enabled" do
      raw = { "assignments" => { "node-1:mod-a" => { "enabled" => "yes" } } }
      result = described_class.call(raw)
      expect(result.ok?).to be false
      expect(result.errors["assignments.node-1:mod-a.enabled"]).to include(/must be true or false/)
    end

    it "rejects unknown module.variety value" do
      raw = { "modules" => { "mod-a" => { "variety" => "weird" } } }
      result = described_class.call(raw)
      expect(result.ok?).to be false
      expect(result.errors["modules.mod-a.variety"]).to include(/subscription\|role\|config\|instance/)
    end

    it "rejects non-integer module.priority" do
      raw = { "modules" => { "mod-a" => { "priority" => "100" } } }
      result = described_class.call(raw)
      expect(result.ok?).to be false
      expect(result.errors["modules.mod-a.priority"]).to include(/must be an integer/)
    end

    it "rejects unknown fleet.* keys" do
      raw = { "fleet" => { "weird_key" => "x" } }
      result = described_class.call(raw)
      expect(result.ok?).to be false
      expect(result.errors["fleet.weird_key"]).to include(/unknown key/)
    end

    it "aggregates multiple errors instead of stopping at the first" do
      raw = {
        "templates"   => { "foo" => { "node_platform" => 42 } },
        "modules"     => { "mod-a" => { "variety" => "weird" } },
        "assignments" => { "bad-key" => {} }
      }
      result = described_class.call(raw)
      expect(result.ok?).to be false
      # 3 distinct errors should surface
      expect(result.errors.size).to be >= 3
      expect(result.errors.keys).to include(
        "templates.foo.node_platform",
        "modules.mod-a.variety",
        "assignments.bad-key"
      )
    end

    it "Result#error_summary concatenates errors with JSON-pointer paths" do
      result = described_class.call({ "templates" => { "foo" => { "node_platform" => 42 } } })
      expect(result.error_summary).to include("templates.foo.node_platform: must be a string")
    end
  end

  describe "integration with DesiredStateParser" do
    it "wires validation errors into parser Result.error" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "fleet.yaml"), <<~YAML)
          templates:
            foo:
              node_platform: 42
        YAML
        result = System::Gitops::DesiredStateParser.parse!(work_tree_path: dir)
        expect(result.ok?).to be false
        expect(result.error).to include("fleet.yaml schema errors")
        expect(result.error).to include("must be a string")
      end
    end
  end
end
