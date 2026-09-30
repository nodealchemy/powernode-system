# frozen_string_literal: true

require "rails_helper"

# IMP-06cf44531256 — the operator grant that lets a module run with
# security.privileged=true (all on-node confinement off) is a PROTECTED
# SiteSetting, written only through the human-only site_setting_set_protected
# door. Before this the key was registered nowhere: the only way to grant it was
# a direct SQL write to accounts.settings, which left no audit trail.
RSpec.describe System::PrivilegedModuleAllowlist do
  let(:account) { create(:account) }
  let(:node_module) { create(:system_node_module, account: account) }
  let(:other_module) { create(:system_node_module, account: account) }

  def key = described_class::SETTING_KEY

  describe "registration" do
    let(:spec) { ::Ai::Tools::SiteSettingTool.operator_configurable_keys[key] }

    it "is registered as a JSON setting" do
      expect(spec).to include(setting_type: "json")
    end

    it "is PROTECTED, so its only write door is the human-only verb" do
      expect(spec[:protected]).to be true
      expect(::Ai::Tools::SiteSettingTool.protected_key?(key)).to be true
      expect(::Ai::Tools::SiteSettingTool.protected_key?(key.upcase)).to be true
    end

    it "is NOT machine-parkable: an instance principal may not even ask for a privilege grant" do
      expect(spec[:machine_parkable]).to be false
    end

    it "refuses a value that is not a list of existing module ids, through SiteSetting itself" do
      row = SiteSetting.new(key: key, setting_type: "json", value: %(["nope"]), is_public: false)
      expect(row).not_to be_valid
      expect(row.errors[:value].join).to match(/module id/i)
    end
  end

  describe ".declaration_problem" do
    it "accepts a list of existing NodeModule ids and the empty list" do
      expect(described_class.declaration_problem([ node_module.id ].to_json)).to be_nil
      expect(described_class.declaration_problem([ node_module.id, other_module.id ].to_json)).to be_nil
      expect(described_class.declaration_problem("[]")).to be_nil
    end

    it "refuses JSON that is not an array" do
      expect(described_class.declaration_problem(%({"a":1}))).to be_present
      expect(described_class.declaration_problem(%("#{node_module.id}"))).to be_present
      expect(described_class.declaration_problem("not json")).to be_present
    end

    it "refuses a module NAME: a name is mutable and author-influenced, only the id is a grant" do
      expect(described_class.declaration_problem([ node_module.name ].to_json)).to be_present
    end

    it "refuses entries that are not strings" do
      expect(described_class.declaration_problem("[1]")).to be_present
      expect(described_class.declaration_problem("[null]")).to be_present
      expect(described_class.declaration_problem(%([["#{node_module.id}"]]))).to be_present
    end

    it "refuses a well-formed UUID that names no NodeModule" do
      expect(described_class.declaration_problem([ SecureRandom.uuid ].to_json)).to be_present
    end

    it "refuses the whole list when ANY one entry is bad" do
      expect(described_class.declaration_problem([ node_module.id, SecureRandom.uuid ].to_json)).to be_present
    end
  end

  describe ".configured_ids" do
    it "is empty when the setting is unset (default deny)" do
      expect(described_class.configured_ids).to eq([])
    end

    it "returns the ids of the stored list" do
      SiteSetting.set(key, [ node_module.id ].to_json, setting_type: "json")
      expect(described_class.configured_ids).to eq([ node_module.id.to_s ])
    end

    it "fails CLOSED on a stored value that is not a list of strings" do
      SiteSetting.new(key: key, setting_type: "string", value: "whatever", is_public: false).save!(validate: false)
      expect(described_class.configured_ids).to eq([])
    end

    it "fails closed when the row holds a JSON object" do
      row = SiteSetting.new(key: key, setting_type: "json", value: %({"a":1}), is_public: false)
      row.save!(validate: false)
      expect(described_class.configured_ids).to eq([])
    end
  end

  # A sibling registration raising must not leave this key unregistered: the REST
  # door would then take it as an ordinary setting, with no value check.
  describe "registration isolation" do
    it "is registered by its own to_prepare block, ahead of the block that registers the other keys" do
      source = File.read(PowernodeSystem::Engine.root.join("lib/powernode_system/engine.rb"))
      own = source.index("::System::PrivilegedModuleAllowlist::SETTING_KEY,\n          setting_type")
      other = source.index("::System::SshExecutionService::REQUIRE_HOST_KEY_SETTING")
      blocks = source[0...own].scan("config.to_prepare do").size
      other_blocks = source[0...other].scan("config.to_prepare do").size

      expect(own).to be_present
      expect(blocks).to be < other_blocks, "the allowlist key shares a to_prepare block with a sibling registration"
    end

    it "registers the value check with SiteSetting" do
      expect(SiteSetting.value_checks).to include(key)
    end
  end
end
