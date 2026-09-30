# frozen_string_literal: true

require "rails_helper"

# IMP-78bc3b20ee94 — the approval card for a change to the privileged-module
# grant showed a list of bare UUIDs a person cannot tell apart. The extension
# registers a presenter on core's SiteSetting seam that puts each module's name
# and owning account next to its id. The raw value stays on the card, the id is
# always in every row, and nothing but the module name and the owner's name is
# ever added.
RSpec.describe System::PrivilegedModuleAllowlist, ".present" do
  let(:owner) { create(:account, name: "Acme Fleet") }
  let(:foreign_owner) { create(:account, name: "Other Tenant") }
  let(:mod) { create(:system_node_module, account: owner, name: "dev-cell-tools") }
  let(:foreign_mod) { create(:system_node_module, account: foreign_owner, name: "foreign-thing") }

  def key = described_class::SETTING_KEY

  it "is registered as the key's presenter" do
    expect(SiteSetting.value_presenters).to have_key(key)
    expect(SiteSetting.present_value(key, [ mod.id ].to_json)).to eq(
      [ { "value" => mod.id, "label" => "dev-cell-tools", "detail" => "owner account: Acme Fleet" } ]
    )
  end

  it "names the module and its owning account for each id, foreign accounts included, in the listed order" do
    rows = described_class.present([ foreign_mod.id, mod.id ].to_json)

    expect(rows).to eq([
      { value: foreign_mod.id, label: "foreign-thing", detail: "owner account: Other Tenant" },
      { value: mod.id, label: "dev-cell-tools", detail: "owner account: Acme Fleet" }
    ])
  end

  it "adds nothing else about a module: no config, no other columns" do
    rows = described_class.present([ mod.id ].to_json)

    expect(rows.flat_map(&:keys).uniq).to contain_exactly(:value, :label, :detail)
  end

  it "shows a deleted module's id as unknown and never raises" do
    gone_id = mod.id
    mod.destroy!

    expect(described_class.present([ gone_id ].to_json)).to eq(
      [ { value: gone_id, label: "(unknown)", detail: nil } ]
    )
  end

  it "shows an entry that is not a module id as unknown, keeping the entry" do
    expect(described_class.present(%(["not-a-uuid"]))).to eq([ { value: "not-a-uuid", label: "(unknown)", detail: nil } ])
  end

  it "reflects a rename made after the request was parked (it reads live rows)" do
    id = mod.id
    mod.update_columns(name: "renamed-since")

    expect(described_class.present([ id ].to_json).first[:label]).to eq("renamed-since")
  end

  it "returns nil for a value that is not a list of strings, leaving the raw value alone" do
    expect(described_class.present("not json")).to be_nil
    expect(described_class.present(%({"a":1}))).to be_nil
    expect(described_class.present(nil)).to be_nil
  end

  it "is one query for the modules and their owners, however many ids" do
    mods = create_list(:system_node_module, 6, account: owner)
    ids = mods.map(&:id)
    described_class.present(ids.to_json) # warm schema/prepared statements

    queries = []
    counter = ->(*, payload) { queries << payload[:sql] unless payload[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { described_class.present(ids.to_json) }

    expect(queries.size).to eq(1), queries.join("\n")
  end

  it "passes a hostile name through as text for the card to escape, with control characters removed by core" do
    hostile = create(:system_node_module, account: owner)
    hostile.update_columns(name: "x<img src=x onerror=alert(1)>‮")

    row = SiteSetting.present_value(key, [ hostile.id ].to_json).first

    expect(row["label"]).to eq("x<img src=x onerror=alert(1)>")
    expect(row["value"]).to eq(hostile.id)
  end

  describe "on the approval card" do
    let(:account) { create(:account) }
    let(:approver) { create(:user, account: account, permissions: %w[admin.access ai.agents.read ai.autonomy.approve]) }
    let(:viewer) { create(:user, account: account, permissions: %w[ai.agents.read]) }

    def card_for(user, value)
      ::Ai::Tools::SiteSettingTool.approval_change_card(
        action: "site_setting_set_protected", tool_params: { key: key, value: value }, viewer: user
      )
    end

    it "shows the approver the raw value AND the presentation; a viewer without setting access gets the raw value only" do
      value = [ foreign_mod.id ].to_json

      shown = card_for(approver, value)
      hidden = card_for(viewer, value)

      expect(shown[:new_value]).to eq(value)
      expect(shown[:presented_new_value].map { |r| [ r["value"], r["label"], r["detail"] ] }).to eq(
        [ [ foreign_mod.id, "foreign-thing", "owner account: Other Tenant" ] ]
      )
      expect(hidden).to include(new_value: value)
      expect(hidden.to_json).not_to include("foreign-thing", "Other Tenant")
    end

    it "still returns the card, raw value only, when the presenter's lookup fails" do
      allow(::System::NodeModule).to receive(:where).and_raise(ActiveRecord::StatementInvalid, "boom")
      value = [ mod.id ].to_json

      card = card_for(approver, value)

      expect(card).to include(new_value: value)
      expect(card).not_to have_key(:presented_new_value)
    end
  end
end
