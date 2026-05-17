# frozen_string_literal: true

require "rails_helper"
require "tmpdir"
require "yaml"

RSpec.describe System::Federation::InventoryRegistry, type: :service do
  # Build an isolated temp tree mimicking the extensions/ layout so we
  # don't depend on whatever's installed in the real repo.
  let(:tmp_root) { Dir.mktmpdir("inventory_registry_spec") }

  before do
    ext_dir = File.join(tmp_root, "extensions", "demo")
    FileUtils.mkdir_p(ext_dir)
    File.write(File.join(ext_dir, "federation_inventory.yaml"), <<~YAML)
      extension: demo
      exportable_kinds:
        - kind: skill
          dependencies: [learning]
          duplicable: true
          migratable: false
        - kind: trading_strategy
          dependencies: [skill]
          duplicable: true
          migratable: true
    YAML

    described_class.extensions_root = tmp_root
    described_class.reload!
  end

  after do
    FileUtils.rm_rf(tmp_root)
    described_class.extensions_root = nil
    described_class.install_test_double(nil)
  end

  describe ".all_kinds" do
    it "returns every kind discovered across extensions" do
      kinds = described_class.all_kinds.map(&:kind)
      expect(kinds).to match_array(%w[skill trading_strategy])
    end
  end

  describe ".find_kind" do
    it "returns the Kind struct by name" do
      record = described_class.find_kind("skill")
      expect(record.extension).to eq("demo")
      expect(record.dependencies).to eq([ "learning" ])
      expect(record.duplicable).to be true
      expect(record.migratable).to be false
    end

    it "is symbol/string indifferent" do
      expect(described_class.find_kind(:trading_strategy)).to be_present
    end

    it "returns nil for unknown kinds" do
      expect(described_class.find_kind("nonexistent")).to be_nil
    end
  end

  describe ".for_extension" do
    it "groups kinds by their declaring extension" do
      records = described_class.for_extension("demo")
      expect(records.size).to eq(2)
      expect(records.map(&:kind)).to match_array(%w[skill trading_strategy])
    end
  end

  describe ".kind_known?" do
    it "is true for declared kinds" do
      expect(described_class.kind_known?("skill")).to be true
    end

    it "is false for unknown kinds" do
      expect(described_class.kind_known?("rogue_kind")).to be false
    end
  end

  describe ".reload!" do
    it "re-reads disk after the yaml changes" do
      ext_yaml = File.join(tmp_root, "extensions", "demo", "federation_inventory.yaml")
      data = YAML.safe_load(File.read(ext_yaml))
      data["exportable_kinds"] << { "kind" => "new_kind" }
      File.write(ext_yaml, data.to_yaml)

      expect(described_class.kind_known?("new_kind")).to be false
      described_class.reload!
      expect(described_class.kind_known?("new_kind")).to be true
    end
  end

  describe "disabled-extension skip" do
    it "skips kinds from disabled extensions" do
      state_path = File.join(tmp_root, "config", "extensions_state.json")
      FileUtils.mkdir_p(File.dirname(state_path))
      File.write(state_path, { "disabled" => [ "demo" ] }.to_json)
      described_class.reload!

      expect(described_class.all_kinds).to be_empty
    end
  end

end
