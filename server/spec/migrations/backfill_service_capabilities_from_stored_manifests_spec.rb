# frozen_string_literal: true

require "rails_helper"
require Rails.root.join(
  "../extensions/system/server/db/migrate/20260925100000_backfill_service_capabilities_from_stored_manifests.rb"
)

# IMP-caef5c00d63f — stage 1 shipped no backfill, so a row written before the
# presence-preserving import holds [] even where its manifest OMITS the key.
# The manifests are stored (NodeModule#manifest_yaml), so this migration
# re-derives each unflagged row from its module's stored manifest:
# - key absent (or null)   -> NULL, flagged (exact re-import semantics)
# - non-empty list         -> copied, flagged
# - declared []            -> [], NOT flagged: a stored manifest may be a
#   pre-sweep version whose [] is boilerplate, so the module keeps no marker
#   until a real import of the swept manifest flags it
# - unparseable manifest / service not found -> untouched, unflagged
RSpec.describe BackfillServiceCapabilitiesFromStoredManifests do
  subject(:migration) { described_class.new }

  let(:account) { create(:account) }

  def module_with(manifest_yaml)
    create(:system_node_module, account: account, manifest_yaml: manifest_yaml)
  end

  def legacy_row(mod, name, capabilities: [])
    create(:system_module_service, node_module: mod, account: account, name: name,
           capabilities: capabilities, capabilities_presence_recorded: false)
  end

  def run_up
    migration.migrate(:up)
  end

  let(:stored_yaml) do
    <<~YAML
      name: demo
      security:
        capabilities: [CAP_CHOWN, CAP_NET_BIND_SERVICE]
      services:
        - name: absent
          start_command: x
        - name: declared-empty
          start_command: x
          capabilities: []
        - name: declared-list
          start_command: x
          capabilities: [CAP_NET_BIND_SERVICE]
    YAML
  end

  it "re-derives each row from the stored manifest with the refined flag rule" do
    mod = module_with(stored_yaml)
    absent = legacy_row(mod, "absent")
    empty  = legacy_row(mod, "declared-empty")
    list   = legacy_row(mod, "declared-list", capabilities: %w[CAP_NET_BIND_SERVICE])

    run_up

    expect(absent.reload.capabilities).to be_nil
    expect(absent.capabilities_presence_recorded).to be(true)

    expect(empty.reload.capabilities).to eq([])
    expect(empty.capabilities_presence_recorded).to be(false)

    expect(list.reload.capabilities).to eq(%w[CAP_NET_BIND_SERVICE])
    expect(list.capabilities_presence_recorded).to be(true)
  end

  it "leaves a module with an old declared [] unmarked (the agent keeps legacy inherit mode)" do
    mod = module_with(stored_yaml)
    legacy_row(mod, "absent")
    legacy_row(mod, "declared-empty")
    legacy_row(mod, "declared-list", capabilities: %w[CAP_NET_BIND_SERVICE])

    run_up

    payload = System::NodeModuleNodeApiSerializer.new(mod.reload).full
    expect(payload).not_to have_key(:service_capabilities_presence)
  end

  it "marks a module whose stored manifest has no declared [] at all" do
    mod = module_with(<<~YAML)
      name: clean
      security:
        capabilities: [CAP_DAC_READ_SEARCH]
      services:
        - name: sidekiq
          start_command: x
    YAML
    legacy_row(mod, "sidekiq")

    run_up

    expect(System::NodeModuleNodeApiSerializer.new(mod.reload).full[:service_capabilities_presence]).to be(true)
  end

  it "leaves every row untouched and unflagged when the stored manifest does not parse" do
    mod = module_with("services: [unclosed")
    row = legacy_row(mod, "absent")

    run_up

    expect(row.reload.capabilities).to eq([])
    expect(row.capabilities_presence_recorded).to be(false)
  end

  it "leaves a row untouched when its service is missing from the stored manifest" do
    mod = module_with(stored_yaml)
    row = legacy_row(mod, "not-in-manifest")

    run_up

    expect(row.reload.capabilities).to eq([])
    expect(row.capabilities_presence_recorded).to be(false)
  end

  it "never touches a row a real import already flagged (the import is authoritative)" do
    mod = module_with(stored_yaml)
    imported = create(:system_module_service, node_module: mod, account: account, name: "absent",
                      capabilities: %w[CAP_CHOWN], capabilities_presence_recorded: true)

    run_up

    expect(imported.reload.capabilities).to eq(%w[CAP_CHOWN])
    expect(imported.capabilities_presence_recorded).to be(true)
  end

  it "is idempotent" do
    mod = module_with(stored_yaml)
    absent = legacy_row(mod, "absent")
    empty  = legacy_row(mod, "declared-empty")

    run_up
    run_up

    expect(absent.reload.capabilities).to be_nil
    expect(absent.capabilities_presence_recorded).to be(true)
    expect(empty.reload.capabilities).to eq([])
    expect(empty.capabilities_presence_recorded).to be(false)
  end

  it "down restores [] for NULL and clears every flag" do
    mod = module_with(stored_yaml)
    absent = legacy_row(mod, "absent")

    run_up
    migration.migrate(:down)

    expect(absent.reload.capabilities).to eq([])
    expect(absent.capabilities_presence_recorded).to be(false)
  end

  it "after a fresh import of the swept manifest, a declared [] is flagged and the module is marked" do
    platform = create(:system_node_platform, account: account)
    category = create(:system_node_module_category, account: account)
    mod = create(:system_node_module, account: account, node_platform: platform, category: category,
                 variety: "subscription", name: "swept", manifest_yaml: stored_yaml)
    legacy_row(mod, "declared-empty")
    run_up
    expect(System::NodeModuleNodeApiSerializer.new(mod.reload).full).not_to have_key(:service_capabilities_presence)

    swept = <<~YAML
      schema_version: 1
      name: swept
      display_name: "Swept"
      description: "swept manifest"
      license: "MIT"
      security:
        capabilities: [CAP_NET_BIND_SERVICE]
        egress_allow: []
        privileged: false
      services:
        - name: declared-empty
          start_command: "x"
          user: root
          capabilities: []
    YAML
    result = System::ManifestImportService.import!(node_module: mod, yaml: swept)
    expect(result.ok?).to be(true), result.validation_errors.inspect

    expect(mod.reload.module_services.find_by(name: "declared-empty").capabilities_presence_recorded).to be(true)
    expect(System::NodeModuleNodeApiSerializer.new(mod).full[:service_capabilities_presence]).to be(true)
  end
end
