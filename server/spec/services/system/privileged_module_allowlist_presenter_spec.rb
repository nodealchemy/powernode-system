# frozen_string_literal: true

require "rails_helper"

# IMP-78bc3b20ee94 — the approval card for a change to the privileged-module
# grant showed a list of bare UUIDs a person cannot tell apart. The extension
# registers a presenter on core's SiteSetting seam that puts each module's name
# and owning account next to its id, as separate fields, with "unknown" and
# "another account" as flags the SERVER computes (never text in a tenant's slot).
# The raw value stays on the card, the id is in every item, and nothing but the
# module name and the owner's name is ever added.
RSpec.describe System::PrivilegedModuleAllowlist, ".present" do
  let(:owner) { create(:account, name: "Acme Fleet") }
  let(:foreign_owner) { create(:account, name: "Other Tenant") }
  let(:mod) { create(:system_node_module, account: owner, name: "dev-cell-tools") }
  let(:foreign_mod) { create(:system_node_module, account: foreign_owner, name: "foreign-thing") }
  let(:approver) { create(:user, account: owner, permissions: %w[admin.access ai.agents.read]) }

  def key = described_class::SETTING_KEY

  def present(ids, viewer: approver) = described_class.present(Array(ids).to_json, viewer)

  it "is registered as the key's presenter" do
    expect(SiteSetting.value_presenters).to have_key(key)
    expect(SiteSetting.present_value(key, [ mod.id ].to_json, viewer: approver)).to eq(
      "items" => [ { "raw" => mod.id, "fields" => { "name" => "dev-cell-tools", "owner" => "Acme Fleet" }, "flags" => [] } ],
      "omitted" => 0
    )
  end

  it "gives each id its module name and owner as separate fields, in the listed order, and flags a foreign account" do
    presented = present([ foreign_mod.id, mod.id ])

    expect(presented[:items]).to eq([
      { raw: foreign_mod.id, fields: { name: "foreign-thing", owner: "Other Tenant" }, flags: [ "other_account" ] },
      { raw: mod.id, fields: { name: "dev-cell-tools", owner: "Acme Fleet" }, flags: [] }
    ])
    expect(presented[:omitted]).to eq(0)
  end

  it "adds nothing else about a module or an account" do
    item = present([ mod.id ])[:items].first

    expect(item.keys).to contain_exactly(:raw, :fields, :flags)
    expect(item[:fields].keys).to contain_exactly(:name, :owner)
  end

  it "flags a deleted module unknown, with no fields, and never raises" do
    gone_id = mod.id
    mod.destroy!

    expect(present([ gone_id ])[:items]).to eq([ { raw: gone_id, fields: {}, flags: [ "unknown" ] } ])
  end

  it "does NOT flag a live module unknown because its name says so" do
    liar = create(:system_node_module, account: owner)
    liar.update_columns(name: "(unknown)")

    item = present([ liar.id ])[:items].first

    expect(item[:flags]).to eq([])
    expect(item[:fields][:name]).to eq("(unknown)")
  end

  it "flags an entry that is not a module id unknown, keeping the entry" do
    expect(present([ "not-a-uuid" ])[:items]).to eq([ { raw: "not-a-uuid", fields: {}, flags: [ "unknown" ] } ])
  end

  it "reflects a rename made after the request was parked (it reads live rows)" do
    id = mod.id
    mod.update_columns(name: "renamed-since")

    expect(present([ id ])[:items].first[:fields][:name]).to eq("renamed-since")
  end

  it "returns nil for a value that is not a list of strings, leaving the raw value alone" do
    expect(described_class.present("not json", approver)).to be_nil
    expect(described_class.present(%({"a":1}), approver)).to be_nil
    expect(described_class.present(nil, approver)).to be_nil
  end

  it "is one query for the modules and their owners, however many ids" do
    ids = create_list(:system_node_module, 6, account: owner).map(&:id)
    present(ids) # warm schema/prepared statements

    queries = []
    counter = ->(*, payload) { queries << payload[:sql] unless payload[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { present(ids) }

    expect(queries.size).to eq(1), queries.join("\n")
  end

  it "presents only the first PRESENTED_ROW_LIMIT ids and counts the rest, so the query is bounded" do
    ids = Array.new(SiteSetting::PRESENTED_ROW_LIMIT + 5) { SecureRandom.uuid }

    presented = present(ids)

    expect(presented[:items].size).to eq(SiteSetting::PRESENTED_ROW_LIMIT)
    expect(presented[:omitted]).to eq(5)
  end

  it "hands core a hostile name as ONE sanitized field and no extra item" do
    hostile = create(:system_node_module, account: owner)
    hostile.update_columns(name: "x\u{2028}\u{201C}(owner account: Mine)\u{201D} 22222222-2222-4222-8222-222222222222\u{202E}")

    presented = SiteSetting.present_value(key, [ hostile.id ].to_json, viewer: approver)

    expect(presented["items"].size).to eq(1)
    expect(presented["items"].first["raw"]).to eq(hostile.id)
    expect(presented["items"].first["fields"]["name"]).not_to match(/[\p{C}\p{Z}&&[^ ]]/)
    expect(presented["items"].first["fields"].keys).to contain_exactly("name", "owner")
  end

  describe "on the approval card" do
    let(:viewer) { create(:user, account: owner, permissions: %w[ai.agents.read]) }
    let(:manager) { create(:user, account: owner, permissions: %w[settings.manage ai.agents.read]) }

    def card_for(user, value)
      ::Ai::Tools::SiteSettingTool.approval_change_card(
        action: "site_setting_set_protected", tool_params: { key: key, value: value }, viewer: user
      )
    end

    it "shows an admin.access holder the raw value AND the presentation; everyone else the raw value only" do
      value = [ foreign_mod.id ].to_json

      shown = card_for(approver, value)

      expect(shown[:new_value]).to eq(value)
      expect(shown[:presented_new_value]["items"]).to eq(
        [ { "raw" => foreign_mod.id, "fields" => { "name" => "foreign-thing", "owner" => "Other Tenant" }, "flags" => [ "other_account" ] } ]
      )
      [ viewer, manager ].each do |other|
        hidden = card_for(other, value)
        expect(hidden).to include(new_value: value)
        expect(hidden.to_json).not_to include("foreign-thing", "Other Tenant")
      end
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
