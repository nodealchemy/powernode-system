# frozen_string_literal: true

require "rails_helper"
require Rails.root.join(
  "../extensions/system/server/db/migrate/20260929160000_migrate_privileged_module_ids_to_protected_setting.rb"
)

# IMP-06cf44531256 — the grant that lets a module run unconfined used to live in
# accounts.settings (written by direct SQL on 2026-09-23, no audit trail) and,
# as a fallback, in an unregistered SiteSetting. The node API now reads ONE
# protected setting. A deployment that already holds a grant must keep it: this
# migration moves it, records that it did, and removes the legacy sources.
#
# The migration runs at BOOT on every deployment, and a raising data migration
# crash-loops rails there, so the failure examples matter as much as the
# happy ones: nothing here may raise, and a failure must leave the legacy grant
# where it was rather than half-move it.
RSpec.describe MigratePrivilegedModuleIdsToProtectedSetting do
  subject(:migration) { described_class.new }

  let(:account)       { create(:account) }
  let(:other_account) { create(:account) }
  let(:dev_cell)      { create(:system_node_module, account: account, name: "dev-cell-m") }
  let(:second)        { create(:system_node_module, account: account, name: "second-m") }
  let(:foreign)       { create(:system_node_module, account: other_account, name: "foreign-m") }

  # The legacy row can no longer be created through SiteSetting validations (that
  # is the point), so a fixture that stands for a pre-existing one skips them.
  def legacy_site_setting!(value, type)
    SiteSetting.new(key: "privileged_module_ids", value: value, setting_type: type, is_public: false).save!(validate: false)
  end

  def key = System::PrivilegedModuleAllowlist::SETTING_KEY

  def stored_ids
    row = SiteSetting.find_by(key: key)
    row && JSON.parse(row.value)
  end

  def legacy_account_value(acct) = acct.reload.settings["privileged_module_ids"]

  def run! = migration.suppress_messages { migration.up }

  def audit_rows = AuditLog.where(action: "update_site_setting", resource_type: "SiteSetting").order(:created_at)

  describe "the account-settings source" do
    it "moves an id into the protected setting and removes the legacy value" do
      account.update_columns(settings: account.settings.merge("privileged_module_ids" => [ dev_cell.id ]))

      run!

      expect(stored_ids).to eq([ dev_cell.id.to_s ])
      expect(legacy_account_value(account)).to be_nil
      expect(SiteSetting.find_by(key: key).is_public).to be(false)
    end

    it "RESOLVES a module name to its id, as the node API used to at read time" do
      account.update_columns(settings: account.settings.merge("privileged_module_ids" => [ dev_cell.name ]))

      run!

      expect(stored_ids).to eq([ dev_cell.id.to_s ])
    end

    it "resolves a name only among the modules its account can see, and KEEPS the legacy key for one it cannot" do
      foreign
      account.update_columns(settings: account.settings.merge("privileged_module_ids" => [ "foreign-m" ]))

      run!

      expect(stored_ids).to be_nil, "a foreign module's name must not grant it"
      expect(legacy_account_value(account)).to eq([ "foreign-m" ])
    end

    # The protected setting is GLOBAL. The old reader ran as the node's account,
    # so a grant in account A's settings only ever unconfined A's nodes; moving
    # an entry naming B's module would make it privileged on B's own nodes, which
    # B never granted. Only entries naming a module the granting account OWNS
    # migrate automatically.
    it "does NOT migrate a grant naming ANOTHER account's module by id: kept, logged, left for the operator" do
      account.update_columns(settings: account.settings.merge("privileged_module_ids" => [ foreign.id ]))
      allow(Rails.logger).to receive(:error)

      run!

      expect(stored_ids).to be_nil, "one tenant's grant must never become another tenant's privilege"
      expect(legacy_account_value(account)).to eq([ foreign.id ])
      expect(Rails.logger).to have_received(:error).with(/not auto-migrated/)
    end

    it "does NOT migrate a name resolving to another account's module even when it is assigned to this account's node" do
      shared = create(:system_node_module, account: other_account, name: "shared-public-m", public: true)
      node = create(:system_node, account: account)
      System::NodeModuleAssignment.create!(node: node, node_module: shared, enabled: true, priority: 0)
      account.update_columns(settings: account.settings.merge("privileged_module_ids" => [ "shared-public-m" ]))

      run!

      expect(stored_ids).to be_nil
      expect(legacy_account_value(account)).to eq([ "shared-public-m" ])
    end

    it "moves the entries the account owns and keeps the rest, in one account" do
      account.update_columns(settings: account.settings.merge("privileged_module_ids" => [ dev_cell.id, foreign.id ]))

      run!

      expect(stored_ids).to eq([ dev_cell.id.to_s ])
      expect(legacy_account_value(account)).to eq([ dev_cell.id, foreign.id ])
    end

    it "leaves the other keys of accounts.settings alone" do
      account.update_columns(settings: account.settings.merge("privileged_module_ids" => [ dev_cell.id ], "keep" => "me"))

      run!

      expect(account.reload.settings).to include("keep" => "me")
    end

    it "unions grants across accounts" do
      account.update_columns(settings: account.settings.merge("privileged_module_ids" => [ dev_cell.id ]))
      other_account.update_columns(settings: other_account.settings.merge("privileged_module_ids" => [ foreign.id ]))

      run!

      expect(stored_ids).to match_array([ dev_cell.id.to_s, foreign.id.to_s ])
    end
  end

  describe "the legacy SiteSetting source" do
    it "moves a JSON list and deletes the legacy row" do
      legacy_site_setting!([ dev_cell.id, second.name ].to_json, "json")

      run!

      expect(stored_ids).to match_array([ dev_cell.id.to_s, second.id.to_s ])
      expect(SiteSetting.find_by(key: "privileged_module_ids")).to be_nil
    end

    it "moves a bare string, the shape Array() of a string-typed row produced" do
      legacy_site_setting!(dev_cell.id.to_s, "string")

      run!

      expect(stored_ids).to eq([ dev_cell.id.to_s ])
    end
  end

  describe "an existing protected value" do
    it "is kept: the migration only ever adds what a person has not already granted" do
      SiteSetting.set(key, [ second.id ].to_json, setting_type: "json")
      account.update_columns(settings: account.settings.merge("privileged_module_ids" => [ dev_cell.id ]))

      run!

      expect(stored_ids).to match_array([ dev_cell.id.to_s, second.id.to_s ])
    end
  end

  describe "the audit trail" do
    it "records one row per account touched, naming the key and the ids, in the audit chain" do
      account.update_columns(settings: account.settings.merge("privileged_module_ids" => [ dev_cell.id ]))

      expect { run! }.to change { audit_rows.count }.by(1)

      row = audit_rows.last
      expect(row.account_id).to eq(account.id)
      expect(row.resource_id).to eq(SiteSetting.find_by(key: key).id)
      expect(row.metadata).to include("setting_key" => key, "migrated_module_ids" => [ dev_cell.id.to_s ])
      expect(row.integrity_hash).to be_present
    end

    it "moves what it CAN resolve, names what it could not, and KEEPS the legacy key so nothing is dropped" do
      account.update_columns(settings: account.settings.merge("privileged_module_ids" => [ dev_cell.id, "no-such-module" ]))
      allow(Rails.logger).to receive(:error)

      run!

      expect(stored_ids).to eq([ dev_cell.id.to_s ])
      expect(audit_rows.last.metadata).to include("unresolved_entries" => [ "no-such-module" ])
      expect(legacy_account_value(account)).to eq([ dev_cell.id, "no-such-module" ])
      expect(Rails.logger).to have_received(:error).with(/"no-such-module".*legacy source is kept/)
    end

    it "keeps an all-unresolved legacy grant untouched and writes neither setting nor audit row" do
      account.update_columns(settings: account.settings.merge("privileged_module_ids" => [ "no-such-module" ]))

      expect { run! }.not_to(change { audit_rows.count })

      expect(stored_ids).to be_nil
      expect(legacy_account_value(account)).to eq([ "no-such-module" ])
    end

    it "does not audit again on a re-run that moves nothing new" do
      account.update_columns(settings: account.settings.merge("privileged_module_ids" => [ dev_cell.id, "no-such-module" ]))
      run!

      expect { run! }.not_to(change { audit_rows.count })
    end

    it "audits a global-setting source under the platform (oldest) account, not the account that owns the module" do
      legacy_site_setting!([ foreign.id ].to_json, "json")
      platform = Account.order(:created_at, :id).first

      run!

      expect(stored_ids).to eq([ foreign.id.to_s ])
      expect(audit_rows.map(&:account_id)).to eq([ platform.id ])
    end
  end

  describe "when there is nothing to migrate" do
    it "does nothing and does not create the setting" do
      expect { run! }.not_to(change { [ SiteSetting.count, audit_rows.count ] })
      expect(SiteSetting.find_by(key: key)).to be_nil
    end

    it "is idempotent" do
      account.update_columns(settings: account.settings.merge("privileged_module_ids" => [ dev_cell.id ]))
      run!

      expect { run! }.not_to(change { [ stored_ids, audit_rows.count ] })
    end

    it "ignores an empty or blank legacy value without granting anything" do
      account.update_columns(settings: account.settings.merge("privileged_module_ids" => [ "", nil ]))

      expect { run! }.not_to raise_error
      expect(stored_ids).to be_nil
    end
  end

  describe "failure" do
    before do
      account.update_columns(settings: account.settings.merge("privileged_module_ids" => [ dev_cell.id ]))
    end

    it "never raises, and leaves the legacy grant in place when the write fails" do
      allow(AuditLog).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, "boom")
      allow(Rails.logger).to receive(:error)

      expect { run! }.not_to raise_error

      expect(legacy_account_value(account)).to eq([ dev_cell.id ])
      expect(SiteSetting.find_by(key: key)).to be_nil
      expect(Rails.logger).to have_received(:error).with(/PrivilegedAllowlistLegacyMigration.*not migrated/)
    end

    it "survives a malformed legacy value of an unexpected shape" do
      account.update_columns(settings: account.settings.merge("privileged_module_ids" => { "a" => 1 }))

      expect { run! }.not_to raise_error
      expect(stored_ids).to be_nil
    end

    it "can be RETRIED after a failure: the same grant moves on the next run" do
      allow(AuditLog).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, "boom")
      run!
      expect(stored_ids).to be_nil
      allow(AuditLog).to receive(:create!).and_call_original

      result = System::PrivilegedAllowlistLegacyMigration.call

      expect(result).to be_ok
      expect(stored_ids).to eq([ dev_cell.id.to_s ])
      expect(legacy_account_value(account)).to be_nil
    end

    it "does not raise even when the service itself blows up" do
      allow(System::PrivilegedAllowlistLegacyMigration).to receive(:call).and_raise(NameError, "boom")

      expect { run! }.not_to raise_error
    end

    it "skips an account whose settings is not an object, and still moves the others" do
      other_account.update_columns(settings: other_account.settings.merge("privileged_module_ids" => [ foreign.id ]))
      ActiveRecord::Base.connection.execute(
        "UPDATE accounts SET settings = '[\"privileged_module_ids\"]'::jsonb WHERE id = '#{account.id}'"
      )

      expect { run! }.not_to raise_error

      expect(stored_ids).to eq([ foreign.id.to_s ])
    end

    it "survives an account whose settings column is null" do
      Account.where(id: account.id).update_all("settings = NULL")

      expect { run! }.not_to raise_error
    end
  end

  describe "every removal of a legacy source is audited" do
    it "writes an audit row for a discard run even when nothing new moved" do
      account.update_columns(settings: account.settings.merge("privileged_module_ids" => [ dev_cell.id, "no-such-module" ]))
      run!
      expect(audit_rows.count).to eq(1)

      System::PrivilegedAllowlistLegacyMigration.call(discard_unresolved: true)

      expect(legacy_account_value(account)).to be_nil
      expect(audit_rows.count).to eq(2), "a discard that removed a source left no audit row"
      expect(audit_rows.last.metadata).to include("unresolved_entries" => [ "no-such-module" ],
                                                  "unresolved_discarded" => true, "legacy_source_removed" => true)
    end

    it "audits a discard when nothing at all resolved (no setting row exists to point at)" do
      account.update_columns(settings: account.settings.merge("privileged_module_ids" => [ "no-such-module" ]))

      System::PrivilegedAllowlistLegacyMigration.call(discard_unresolved: true)

      row = AuditLog.where(action: "update_site_setting", account_id: account.id).last
      expect(row).to be_present
      expect(row.metadata).to include("unresolved_discarded" => true, "legacy_source_removed" => true)
      expect(legacy_account_value(account)).to be_nil
    end

    it "audits removing a source whose ids were already granted" do
      SiteSetting.set(key, [ dev_cell.id ].to_json, setting_type: "json")
      account.update_columns(settings: account.settings.merge("privileged_module_ids" => [ dev_cell.id ]))

      expect { run! }.to change { audit_rows.count }.by(1)

      expect(audit_rows.last.metadata).to include("legacy_source_removed" => true, "migrated_module_ids" => [])
    end
  end

  describe "a stale id already in the protected value" do
    it "is dropped while merging, and recorded, instead of failing every retry" do
      gone = create(:system_node_module, account: account, name: "gone-m")
      SiteSetting.set(key, [ gone.id ].to_json, setting_type: "json")
      gone.destroy!
      account.update_columns(settings: account.settings.merge("privileged_module_ids" => [ dev_cell.id ]))

      result = System::PrivilegedAllowlistLegacyMigration.call

      expect(result).to be_ok
      expect(stored_ids).to eq([ dev_cell.id.to_s ])
      expect(audit_rows.last.metadata).to include("dropped_stale_ids" => [ gone.id.to_s ])
    end
  end

  describe "the plan and the rake task" do
    before(:all) { Rails.application.load_tasks unless Rake::Task.task_defined?("system:privileged_allowlist:migrate_legacy") }
    after { Rake::Task["system:privileged_allowlist:migrate_legacy"].reenable }

    let(:operator) { create(:user, account: account, permissions: [ "admin.access" ], email: "operator-#{SecureRandom.hex(3)}@example.test") }

    # [stdout, stderr, exit status or nil]
    def rake!(env = {})
      old = env.keys.to_h { |k| [ k, ENV[k] ] }
      env.each { |k, v| ENV[k] = v }
      out = StringIO.new
      err = StringIO.new
      status = nil
      original = [ $stdout, $stderr ]
      $stdout = out
      $stderr = err
      begin
        Rake::Task["system:privileged_allowlist:migrate_legacy"].reenable
        Rake::Task["system:privileged_allowlist:migrate_legacy"].execute
      rescue SystemExit => e
        status = e.status
      ensure
        $stdout, $stderr = original
        old.each { |k, v| ENV[k] = v }
      end
      [ out.string, err.string, status ]
    end

    before do
      account.update_columns(settings: account.settings.merge("privileged_module_ids" => [ dev_cell.id, foreign.id ]))
    end

    it "PRINTS the plan (entry, module id and name, owning account, disposition) and writes nothing without CONFIRM=1" do
      out, = rake!("CONFIRM" => nil)

      expect(out).to match(/#{dev_cell.id} "dev-cell-m" owned by account #{account.id} => migrate/)
      expect(out).to match(/#{foreign.id} "foreign-m" owned by account #{other_account.id} => foreign/)
      expect(out).to include("dry run: nothing written")
      expect(stored_ids).to be_nil
      expect(legacy_account_value(account)).to eq([ dev_cell.id, foreign.id ])
    end

    it "REFUSES to write with CONFIRM=1 but no OPERATOR" do
      _, err, status = rake!("CONFIRM" => "1", "OPERATOR" => nil)

      expect(err).to match(/OPERATOR/)
      expect(status).to eq(1)
      expect(stored_ids).to be_nil
    end

    it "REFUSES an OPERATOR that names no user" do
      _, err, status = rake!("CONFIRM" => "1", "OPERATOR" => "nobody@example.test")

      expect(err).to match(/OPERATOR/)
      expect(status).to eq(1)
      expect(stored_ids).to be_nil
    end

    it "writes with CONFIRM=1 and a resolvable OPERATOR (email or id), and the audit row names that operator" do
      rake!("CONFIRM" => "1", "OPERATOR" => operator.email)

      expect(stored_ids).to eq([ dev_cell.id.to_s ])
      row = audit_rows.last
      expect(row.user_id).to eq(operator.id)
      expect(row.metadata).to include("actor" => "operator", "operator_id" => operator.id)
    end

    it "REFUSES an OPERATOR who exists but does not hold admin.access: the audit row must name an administrator" do
      plain = create(:user, account: account, permissions: [], email: "plain-#{SecureRandom.hex(3)}@example.test")

      _, err, status = rake!("CONFIRM" => "1", "OPERATOR" => plain.email)

      expect(err).to match(/admin\.access/)
      expect(status).to eq(1)
      expect(stored_ids).to be_nil
      expect(legacy_account_value(account)).to eq([ dev_cell.id, foreign.id ])
    end

    it "accepts a user id as OPERATOR" do
      rake!("CONFIRM" => "1", "OPERATOR" => operator.id.to_s)

      expect(audit_rows.last.user_id).to eq(operator.id)
    end
  end

  describe "System::PrivilegedAllowlistLegacyMigration.call(discard_unresolved: true)" do
    it "removes the unresolved legacy entries after recording them in the audit row" do
      account.update_columns(settings: account.settings.merge("privileged_module_ids" => [ dev_cell.id, "no-such-module" ]))

      System::PrivilegedAllowlistLegacyMigration.call(discard_unresolved: true)

      expect(stored_ids).to eq([ dev_cell.id.to_s ])
      expect(legacy_account_value(account)).to be_nil
      expect(audit_rows.last.metadata).to include("unresolved_entries" => [ "no-such-module" ], "unresolved_discarded" => true)
    end
  end

  it "has no down: a grant cannot be un-migrated into an unaudited place" do
    expect { migration.down }.to raise_error(ActiveRecord::IrreversibleMigration)
  end
end
