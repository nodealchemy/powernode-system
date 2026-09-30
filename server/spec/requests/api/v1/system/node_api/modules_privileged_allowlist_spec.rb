# frozen_string_literal: true

require "rails_helper"

# IMP-06cf44531256 — where the node API's privileged_module_ids comes from, and
# what an operator sees when a module asks for privileged and is not granted.
#
# The gate this feeds is the agent's: it refuses to attach (and compose refuses
# to enable the services of) a module declaring security.privileged=true unless
# its id is in this list. So the single source of truth is what decides whether
# a node's services run, and it must be the protected setting, not a legacy
# account-settings value that any account write could reach.
RSpec.describe "Api::V1::System::NodeApi::Modules#index privileged_module_ids", type: :request do
  let(:account)       { create(:account) }
  let(:platform)      { create(:system_node_platform, account: account) }
  let(:category)      { create(:system_node_module_category, account: account) }
  let(:node_template) { create(:system_node_template, account: account, node_platform: platform) }
  let(:node)          { create(:system_node, account: account, node_template: node_template) }
  let(:instance)      { create(:system_node_instance, node: node, status: "running") }

  let!(:active_cert) do
    System::NodeCertificate.create!(
      node_instance: instance, serial: SecureRandom.hex(16), subject: "CN=#{instance.id}",
      not_before: 1.hour.ago, not_after: 90.days.from_now, issuer_subject: "CN=Powernode Internal CA"
    )
  end

  let(:headers) do
    { "X-Forwarded-Tls-Client-Cert-Info" => CGI.escape(%(Subject="CN=#{instance.id}")) }
  end

  def privileged_module(name)
    create(:system_node_module, account: account, node_platform: platform, category: category,
                                variety: "subscription", name: name, priority: 5,
                                config: { "security" => { "privileged" => true } })
  end

  let!(:dev_cell) { privileged_module("dev-cell-x") }
  let!(:plain)    { create(:system_node_module, account: account, node_platform: platform, category: category,
                                                variety: "subscription", name: "plain-x", priority: 6) }

  before do
    [ dev_cell, plain ].each do |m|
      System::NodeModuleAssignment.create!(node: node, node_module: m, enabled: true, priority: 0)
    end
  end

  # The legacy row can no longer be created through SiteSetting validations (that
  # is the point), so a fixture that stands for a pre-existing one skips them.
  def legacy_site_setting!(value, type)
    SiteSetting.new(key: "privileged_module_ids", value: value, setting_type: type, is_public: false).save!(validate: false)
  end

  def fetch
    get "/api/v1/system/node_api/modules", headers: headers
    expect(response).to have_http_status(:ok)
    JSON.parse(response.body).dig("data", "privileged_module_ids")
  end

  def grant!(*ids)
    SiteSetting.set(System::PrivilegedModuleAllowlist::SETTING_KEY, ids.to_json, setting_type: "json")
  end

  def unapproved_events
    System::FleetEvent.by_kind(System::PrivilegedModuleAllowlist::UNAPPROVED_EVENT_KIND)
  end

  it "is empty by default (deny)" do
    expect(fetch).to eq([])
  end

  it "emits the granted module id from the protected setting" do
    grant!(dev_cell.id)
    expect(fetch).to eq([ dev_cell.id.to_s ])
  end

  it "emits only ids of modules resolved for THIS node: a foreign or stale id is inert" do
    other = create(:system_node_module, account: account, node_platform: platform, category: category,
                                        variety: "subscription", name: "not-on-this-node")
    grant!(dev_cell.id, other.id)
    expect(fetch).to eq([ dev_cell.id.to_s ])
  end

  it "does NOT honour a module NAME, which is mutable and author-influenced" do
    SiteSetting.new(key: System::PrivilegedModuleAllowlist::SETTING_KEY, setting_type: "json",
                    value: [ dev_cell.name ].to_json, is_public: false).save!(validate: false)
    expect(fetch).to eq([])
  end

  it "no longer reads the legacy account-settings value: one source of truth" do
    account.update_columns(settings: (account.settings || {}).merge("privileged_module_ids" => [ dev_cell.id ]))
    expect(fetch).to eq([])
  end

  it "no longer reads the legacy unregistered SiteSetting either" do
    legacy_site_setting!([ dev_cell.id ].to_json, "json")
    expect(fetch).to eq([])
  end

  describe "the visible signal" do
    it "emits a high-severity fleet event for a privileged module that is not granted" do
      expect { fetch }.to change { unapproved_events.count }.by(1)

      event = unapproved_events.last
      expect(event.severity).to eq("high")
      expect(event.node_module_id).to eq(dev_cell.id)
      expect(event.node_instance_id).to eq(instance.id)
      expect(event.payload).to include("module_name" => "dev-cell-x")
    end

    it "does not flag a module that does not declare privileged" do
      fetch
      expect(unapproved_events.pluck(:node_module_id)).not_to include(plain.id)
    end

    it "is silent once the module is granted" do
      grant!(dev_cell.id)
      expect { fetch }.not_to(change { unapproved_events.count })
    end

    it "does not repeat on every poll" do
      fetch
      expect { fetch }.not_to(change { unapproved_events.count })
    end

    it "never breaks the poll when emitting the event fails" do
      allow(System::Fleet::EventBroadcaster).to receive(:emit!).and_raise(StandardError, "boom")
      expect(fetch).to eq([])
    end
  end

  describe "a legacy grant the migration has not moved" do
    def pending_events = System::FleetEvent.by_kind(System::PrivilegedModuleAllowlist::LEGACY_PENDING_EVENT_KIND)

    it "raises a critical fleet event and does NOT honour the legacy value" do
      account.update_columns(settings: account.settings.merge("privileged_module_ids" => [ dev_cell.id ]))
      allow(Rails.logger).to receive(:error)

      expect { expect(fetch).to eq([]) }.to change { pending_events.count }.by(1)

      expect(pending_events.last.severity).to eq("critical")
      expect(pending_events.last.account_id).to eq(account.id)
      expect(pending_events.last.payload["remedy"]).to include("system:privileged_allowlist:migrate_legacy")
      expect(Rails.logger).to have_received(:error).with(/legacy privileged_module_ids grant is still present/)
    end

    it "is NOT raised under an account that holds no legacy key (another tenant's stranded grant is not its alert)" do
      other = create(:account)
      other.update_columns(settings: other.settings.merge("privileged_module_ids" => [ "x" ]))

      expect { fetch }.not_to(change { pending_events.count })
    end

    it "reports a platform-wide legacy SiteSetting only under the platform (oldest) account" do
      legacy_site_setting!([ dev_cell.id ].to_json, "json")
      create(:account).update_columns(created_at: 5.years.ago)

      expect { fetch }.not_to(change { pending_events.count })

      account.update_columns(created_at: 10.years.ago)
      expect { fetch }.to change { pending_events.where(account_id: account.id).count }.by(1)
    end

    it "also fires for the legacy SiteSetting, and is not repeated on every poll" do
      legacy_site_setting!([ dev_cell.id ].to_json, "json")
      account.update_columns(created_at: 10.years.ago)
      fetch

      expect { fetch }.not_to(change { pending_events.count })
      expect(pending_events.count).to eq(1)
    end

    it "stops once the migration has moved the grant" do
      account.update_columns(settings: account.settings.merge("privileged_module_ids" => [ dev_cell.id ]))
      System::PrivilegedAllowlistLegacyMigration.call

      expect { expect(fetch).to eq([ dev_cell.id.to_s ]) }.not_to(change { pending_events.count })
    end

    it "is silent when there is no legacy source" do
      expect { fetch }.not_to(change { pending_events.count })
    end

    it "does not fire for an account whose settings is not an object" do
      odd = create(:account)
      ActiveRecord::Base.connection.execute(
        "UPDATE accounts SET settings = '[\"privileged_module_ids\"]'::jsonb WHERE id = '#{odd.id}'"
      )
      expect { fetch }.not_to(change { pending_events.count })
    end
  end
end
