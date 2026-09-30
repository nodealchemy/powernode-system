# frozen_string_literal: true

module System
  # Moves the privileged-module grant that used to live in
  # accounts.settings["privileged_module_ids"] (and, as a fallback, an
  # unregistered SiteSetting of the same name) into the protected setting
  # System::PrivilegedModuleAllowlist::SETTING_KEY, with an audit row, and
  # removes the legacy source it fully moved (IMP-06cf44531256).
  #
  # A SERVICE, not migration-local code, because a failed move must be
  # retryable: the migration that calls it is stamped in schema_migrations
  # whether it succeeded or not, and it may never raise at boot. So the move is
  # re-runnable on demand (rake system:privileged_allowlist:migrate_legacy) and
  # every poll of the node API keeps a critical fleet event alive while a legacy
  # source remains (PrivilegedModuleAllowlist.report_legacy_pending!).
  #
  # Resolution mirrors what the node API's old reader could match, which was
  # every module RESOLVED for the node, not only the granting account's:
  #   * a UUID entry is resolved by existence alone (an id is globally unique,
  #     and the new value check is existence-only as well);
  #   * a NAME entry is resolved against the granting account's own modules plus
  #     the modules assigned to that account's nodes (public / shared modules);
  #   * the global SiteSetting resolves names across all accounts, as the old
  #     fallback did.
  #
  # ANY entry that stays unresolved KEEPS its legacy source: nothing is dropped,
  # the resolved ids are still moved, and it is logged at ERROR. An operator
  # either fixes the entry and re-runs, or re-runs with discard_unresolved: true,
  # which records the discarded entries in the audit row before removing them.
  #
  # Never raises: a failure is logged and returned, and leaves the legacy source
  # untouched (the move is one transaction). Idempotent.
  class PrivilegedAllowlistLegacyMigration
    LEGACY_KEY = "privileged_module_ids"
    UUID_FORMAT = ::System::PrivilegedModuleAllowlist::UUID_FORMAT

    Result = Struct.new(:moved_ids, :unresolved, :legacy_remaining, :error, keyword_init: true) do
      def ok? = error.nil?
    end

    def self.call(discard_unresolved: false)
      new(discard_unresolved: discard_unresolved).call
    end

    # Accounts whose settings still carry the legacy key. jsonb_typeof guards a
    # settings column that is not an object (jsonb_exists is true for an array
    # holding the string), which would otherwise abort the whole move.
    def self.legacy_accounts
      ::Account.where("jsonb_typeof(settings) = 'object' AND jsonb_exists(settings, ?)", LEGACY_KEY)
    end

    def self.legacy_site_setting
      ::SiteSetting.find_by(key: LEGACY_KEY)
    end

    def self.legacy_present?
      legacy_accounts.exists? || !legacy_site_setting.nil?
    end

    def initialize(discard_unresolved: false)
      @discard = discard_unresolved
    end

    def call
      plan = build_plan
      apply(plan)
    rescue StandardError => e
      ::Rails.logger.error("[PrivilegedAllowlistLegacyMigration] not migrated, legacy grant left in place: #{e.class}: #{e.message}")
      Result.new(moved_ids: [], unresolved: [], legacy_remaining: true, error: "#{e.class}: #{e.message}")
    end

    private

    # What would move and what would be removed, with nothing written yet.
    def build_plan
      plan = { per_account: [], site: nil }
      self.class.legacy_accounts.find_each do |account|
        entries = normalize(account.settings[LEGACY_KEY])
        if entries.nil?
          ::Rails.logger.error("[PrivilegedAllowlistLegacyMigration] accounts.settings of #{account.id} holds an unreadable #{LEGACY_KEY}; left in place")
          next
        end
        ids, missing = resolve(entries, account: account)
        plan[:per_account] << { account: account, ids: ids, unresolved: missing }
      end

      site = self.class.legacy_site_setting
      if site
        entries = normalize(site_entries(site))
        if entries.nil?
          ::Rails.logger.error("[PrivilegedAllowlistLegacyMigration] site_settings #{LEGACY_KEY} is unreadable; left in place")
        else
          ids, missing = resolve(entries, account: nil)
          plan[:site] = { row: site, ids: ids, unresolved: missing }
        end
      end
      plan
    end

    def apply(plan)
      account_plans = plan[:per_account]
      site_plan = plan[:site]
      all_ids = (account_plans.flat_map { |p| p[:ids] } + (site_plan ? site_plan[:ids] : [])).uniq
      unresolved = account_plans.flat_map { |p| p[:unresolved] } + (site_plan ? site_plan[:unresolved] : [])
      unresolved.each do |entry|
        ::Rails.logger.error("[PrivilegedAllowlistLegacyMigration] legacy entry #{entry.inspect} names no module; its legacy source is kept")
      end

      ::ActiveRecord::Base.transaction do
        existing = ::System::PrivilegedModuleAllowlist.configured_ids
        added = all_ids - existing
        row = write_setting((existing + added).uniq) if added.any?

        if row
          account_plans.each do |p|
            new_for_account = p[:ids] - existing
            audit(row, account: p[:account], moved: new_for_account, unresolved: p[:unresolved], source: "accounts.settings") if new_for_account.any?
          end
          # A global-setting grant is not tenant data: audit it against the
          # accounts that own the modules it resolved to, never its unresolved
          # names.
          if site_plan
            new_for_site = site_plan[:ids] - existing
            ::System::NodeModule.where(id: new_for_site).group_by(&:account_id).each do |account_id, mods|
              audit(row, account: ::Account.find(account_id), moved: mods.map { |m| m.id.to_s }, unresolved: [], source: "site_settings.#{LEGACY_KEY}")
            end
          end
        end

        remove_legacy(account_plans, site_plan)
      end

      Result.new(moved_ids: all_ids, unresolved: unresolved, legacy_remaining: self.class.legacy_present?)
    end

    def remove_legacy(account_plans, site_plan)
      account_plans.each do |p|
        next unless p[:unresolved].empty? || @discard

        ::Account.where(id: p[:account].id).update_all([ "settings = settings - ?", LEGACY_KEY ])
      end
      site_plan[:row].destroy if site_plan && (site_plan[:unresolved].empty? || @discard)
    end

    def write_setting(ids)
      ::SiteSetting.set(
        ::System::PrivilegedModuleAllowlist::SETTING_KEY, ids.to_json,
        setting_type: "json", description: "Operator grant for modules declaring security.privileged=true (NodeModule ids).", is_public: false
      )
    end

    def audit(row, account:, moved:, unresolved:, source:)
      ::AuditLog.create!(
        account: account,
        action: "update_site_setting",
        resource_type: "SiteSetting",
        resource_id: row.id,
        source: "system",
        severity: "high",
        risk_level: "high",
        metadata: {
          setting_key: ::System::PrivilegedModuleAllowlist::SETTING_KEY,
          setting_type: "json",
          actor: self.class.name,
          migrated_from: [ source ],
          migrated_module_ids: moved.uniq,
          unresolved_entries: unresolved,
          unresolved_discarded: @discard && unresolved.any?
        }
      )
    end

    # An Array<String> of entries, or nil when the value is not a shape the old
    # reader (Array(raw).map(&:to_s)) would have turned into names/ids.
    def normalize(raw)
      list = case raw
      when nil then []
      when Array then raw
      when String then string_entries(raw)
      end
      return nil unless list.is_a?(Array) && list.all? { |e| e.nil? || e.is_a?(String) }

      list.compact.map(&:strip).reject(&:blank?).uniq
    end

    def string_entries(raw)
      parsed = raw.strip.start_with?("[") ? JSON.parse(raw) : nil
      parsed.is_a?(Array) ? parsed : [ raw ]
    rescue JSON::ParserError
      [ raw ]
    end

    def site_entries(row)
      return row.value.to_s unless row.setting_type == "json"

      JSON.parse(row.value.to_s)
    rescue JSON::ParserError
      nil
    end

    # [ids, unresolved]
    def resolve(entries, account:)
      uuids = entries.grep(UUID_FORMAT)
      by_id = ::System::NodeModule.where(id: uuids).pluck(:id).map(&:to_s)
      by_name = name_candidates(account).where(name: entries).pluck(:id, :name)

      matched = by_id + by_name.map { |_, name| name }
      ids = (by_id + by_name.map { |id, _| id.to_s }).uniq
      [ ids, entries.reject { |e| matched.include?(e) } ]
    end

    # The modules a NAME could have matched in the old reader: the account's own
    # and those on its nodes (base assignments and dependants). No account (the
    # global SiteSetting) means every module.
    def name_candidates(account)
      return ::System::NodeModule.all unless account

      nodes = ::System::Node.where(account_id: account.id)
      assigned = ::System::NodeModuleAssignment.where(node_id: nodes).select(:node_module_id)
      ::System::NodeModule.where(account_id: account.id)
                          .or(::System::NodeModule.where(id: assigned))
                          .or(::System::NodeModule.where(node_id: nodes))
    end
  end
end
