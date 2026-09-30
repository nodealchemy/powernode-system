# frozen_string_literal: true

# IMP-06cf44531256 — move the privileged-module grant into its protected
# setting, with an audit row, and remove the two places it used to live.
#
# The node API's privileged_module_ids (the list the agent's privileged gate
# honours) was read from accounts.settings["privileged_module_ids"], falling
# back to an unregistered SiteSetting of the same name. Nothing registered
# either, so the only way to grant a module unconfined operation was a direct
# SQL write (done once, 2026-09-23, with no audit trail). It is now the
# PROTECTED setting System::PrivilegedModuleAllowlist::SETTING_KEY, written only
# through the human-only site_setting_set_protected.
#
# A deployment that already holds a grant must keep it, so this moves it:
#
#   * every entry is resolved to a NodeModule id (an id stays, a name is looked
#     up within the account it came from, exactly what the node API used to do
#     at read time; the global SiteSetting is looked up across accounts);
#   * the ids are UNIONed into whatever the protected setting already holds, so
#     it never removes a grant a person made through the new door;
#   * one audit row per account touched, in the audit chain, naming the key, the
#     ids moved and any entry that could not be resolved (nothing is dropped
#     silently: an unresolved entry granted nothing before either, since the
#     node API only ever emitted ids of modules that resolved);
#   * only then are the legacy sources removed, so the setting is the single
#     source of truth.
#
# IT MUST NOT RAISE. A data migration that raises at boot crash-loops rails, and
# rails serves the node API the agents poll. So the whole move is one
# transaction inside a rescue that logs and returns: on any failure nothing is
# half-moved and the legacy grant is left where it was, for an operator to
# re-grant through the protected door. (disable_ddl_transaction! so a failed
# statement here cannot poison the transaction schema_migrations is stamped in.)
#
# Self-contained: local models over the tables, no app model whose validations
# could drift, except AuditLog, which is the audit chain and must be written
# through its own callbacks to be part of it. Data-only, idempotent (a re-run
# finds no legacy source), not reversible.
class MigratePrivilegedModuleIdsToProtectedSetting < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  SETTING_KEY = "system.privileged_module_ids"
  LEGACY_KEY  = "privileged_module_ids"
  UUID_FORMAT = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

  class AccountRow < ActiveRecord::Base
    self.table_name = "accounts"
  end

  class ModuleRow < ActiveRecord::Base
    self.table_name = "system_node_modules"
  end

  class SettingRow < ActiveRecord::Base
    self.table_name = "site_settings"
  end

  def up
    move_grants
  rescue StandardError => e
    say "#{self.class.name}: NOT migrated (#{e.class}); the legacy grant is untouched", true
    Rails.logger.error("[#{self.class.name}] not migrated, legacy grant left in place: #{e.class}: #{e.message}")
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          "a grant cannot be moved back into an unaudited legacy location; " \
          "write #{SETTING_KEY} through site_setting_set_protected instead"
  end

  private

  def move_grants
    account_sources = AccountRow.where("jsonb_exists(settings, ?)", LEGACY_KEY).to_a
    site_source     = SettingRow.find_by(key: LEGACY_KEY)
    return if account_sources.empty? && site_source.nil?

    # [account_id, module id] pairs and [account_id, entry] unresolved pairs.
    # The global SiteSetting's account is that of the module an entry resolves
    # to; an entry that resolves to none is attributed to the oldest account.
    resolved   = []
    unresolved = []
    sources    = []
    untouched  = []
    fallback_account_id = AccountRow.order(:created_at, :id).pick(:id)

    account_sources.each do |account|
      entries = normalize(account.settings[LEGACY_KEY])
      if entries.nil?
        untouched << account.id
        say "#{self.class.name}: accounts.settings of #{account.id} holds an unreadable #{LEGACY_KEY}; left in place", true
        next
      end
      sources << "accounts.settings"
      ids, missing = resolve(entries, account_id: account.id)
      ids.each { |id| resolved << [ account.id, id ] }
      missing.each { |entry| unresolved << [ account.id, entry ] }
    end

    site_entries = site_source && normalize_site_value(site_source)
    site_unreadable = site_source && site_entries.nil?
    say "#{self.class.name}: site_settings #{LEGACY_KEY} is unreadable; left in place", true if site_unreadable
    if site_entries
      sources << "site_settings.#{LEGACY_KEY}"
      ids, missing = resolve(site_entries, account_id: nil)
      ids.each { |id, account_id| resolved << [ account_id, id ] }
      missing.each { |entry| unresolved << [ fallback_account_id, entry ] }
    end

    ActiveRecord::Base.transaction do
      row = SettingRow.find_by(key: SETTING_KEY)
      existing = row ? (parse_ids(row.value) || []) : []
      moved = resolved.map(&:last).uniq
      final = (existing + moved).uniq

      if moved.any? || unresolved.any?
        row = write_setting(row, final)
        audit(row, resolved: resolved, unresolved: unresolved, sources: sources.uniq)
      end

      # Only what was read and moved (or read and empty) is removed; an
      # unreadable legacy value stays for an operator to look at.
      readable_account_ids = account_sources.map(&:id) - untouched
      AccountRow.where(id: readable_account_ids).update_all([ "settings = settings - ?", LEGACY_KEY ]) if readable_account_ids.any?
      site_source.destroy if site_entries
    end
  end

  # An Array<String> of entries, or nil when the value is not a shape the old
  # reader (Array(raw).map(&:to_s)) would have turned into a list of names/ids.
  def normalize(raw)
    list = case raw
    when nil then []
    when Array then raw
    when String then string_entries(raw)
    end
    return nil unless list.is_a?(Array)
    return nil unless list.all? { |e| e.nil? || e.is_a?(String) }

    list.compact.map(&:strip).reject(&:blank?).uniq
  end

  def string_entries(raw)
    parsed = raw.strip.start_with?("[") ? JSON.parse(raw) : nil
    parsed.is_a?(Array) ? parsed : [ raw ]
  rescue JSON::ParserError
    [ raw ]
  end

  def normalize_site_value(row)
    row.setting_type == "json" ? normalize(safe_json(row.value)) : normalize(row.value.to_s)
  end

  def safe_json(value)
    JSON.parse(value.to_s)
  rescue JSON::ParserError
    nil
  end

  # [ids, unresolved]. With an account_id, ids is an Array of ids scoped to it;
  # without one (the global SiteSetting) ids is an Array of [id, account_id].
  def resolve(entries, account_id:)
    scope = ModuleRow.all
    scope = scope.where(account_id: account_id) if account_id
    uuids = entries.grep(UUID_FORMAT)
    found = scope.where(id: uuids).or(scope.where(name: entries)).select(:id, :name, :account_id).to_a

    matched = found.flat_map { |m| [ m.id.to_s, m.name.to_s ] }
    missing = entries.reject { |e| matched.include?(e) }
    ids = found.map { |m| account_id ? m.id.to_s : [ m.id.to_s, m.account_id ] }.uniq
    [ ids, missing ]
  end

  def parse_ids(value)
    list = safe_json(value)
    list.is_a?(Array) && list.all?(String) ? list : nil
  end

  def write_setting(row, ids)
    row ||= SettingRow.new(key: SETTING_KEY)
    row.value = ids.to_json
    row.setting_type = "json"
    row.is_public = false
    row.description ||= "Operator grant for modules declaring security.privileged=true (NodeModule ids)."
    row.save!
    row
  end

  def audit(row, resolved:, unresolved:, sources:)
    account_ids = (resolved.map(&:first) + unresolved.map(&:first)).compact.uniq
    account_ids.each do |account_id|
      ::AuditLog.create!(
        account_id: account_id,
        action: "update_site_setting",
        resource_type: "SiteSetting",
        resource_id: row.id,
        source: "system",
        severity: "high",
        risk_level: "high",
        metadata: {
          setting_key: SETTING_KEY,
          setting_type: "json",
          actor: self.class.name,
          migrated_from: sources,
          migrated_module_ids: resolved.select { |a, _| a == account_id }.map(&:last).uniq,
          unresolved_entries: unresolved.select { |a, _| a == account_id }.map(&:last).uniq
        }
      )
    end
  end
end
