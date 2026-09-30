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
  # every poll of the node API keeps a critical fleet event alive, under the
  # account that holds it, while a legacy source remains
  # (PrivilegedModuleAllowlist.report_legacy_pending!).
  #
  # WHAT MOVES AUTOMATICALLY, and why it is narrower than what the old reader
  # honoured. A grant in accounts[A].settings used to take effect only on A's own
  # nodes (the reader ran as the node's account). The protected setting is
  # GLOBAL, so moving an entry into it makes that module privileged on every
  # node that carries it, whoever owns the node. That is only faithful for a
  # module the granting account OWNS: for a module owned by another account it
  # would silently turn one tenant's grant into another tenant's privilege. So:
  #   * an account-settings entry migrates only if it names a module OWNED by
  #     that account (a UUID by id, a name among the account's own modules);
  #   * an entry naming another account's module, or no module, is KEPT in its
  #     legacy location, logged at ERROR, and left for an operator to grant (or
  #     not) through the protected door;
  #   * the global SiteSetting was already platform-level, so it resolves across
  #     accounts (a UUID by existence, a name across all modules).
  # There is no platform-owner account in core to prefer instead, so ownership by
  # the granting account is the rule.
  #
  # ANY entry that is not moved KEEPS its legacy source: nothing is dropped, the
  # entries that did resolve are still moved. An operator either fixes it and
  # re-runs, or re-runs with discard_unresolved: true. EVERY removal of a legacy
  # source, discard or not, writes an audit row.
  #
  # Never raises: a failure is logged and returned, and leaves the legacy source
  # untouched (the move is one transaction). Idempotent.
  class PrivilegedAllowlistLegacyMigration
    LEGACY_KEY = "privileged_module_ids"
    UUID_FORMAT = ::System::PrivilegedModuleAllowlist::UUID_FORMAT

    Result = Struct.new(:moved_ids, :unresolved, :legacy_remaining, :error, keyword_init: true) do
      def ok? = error.nil?
    end

    # One line of the plan: what an entry resolves to and what happens to it.
    PlanRow = Struct.new(:entry, :module_id, :module_name, :owner_account_id, :disposition, keyword_init: true)

    def self.call(discard_unresolved: false, actor: nil)
      new(discard_unresolved: discard_unresolved, actor: actor).call
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

    # The oldest account stands in for "the platform" wherever a platform-wide
    # source (the global SiteSetting) needs an account to be reported under.
    def self.platform_account_id
      ::Account.order(:created_at, :id).pick(:id)
    end

    # Whether THIS account holds a stranded legacy source, and so is the one to
    # be told about it.
    def self.legacy_present_for?(account)
      return false if account.nil?

      legacy_accounts.exists?(id: account.id) || (!legacy_site_setting.nil? && platform_account_id == account.id)
    end

    # Human-readable lines for the plan, for the rake task. Ids, names and the
    # owning accounts only.
    def self.plan_lines(plan)
      plan[:sources].flat_map do |source|
        head = source[:kind] == :account ? "accounts.settings of account #{source[:account].id}" : "site_settings #{LEGACY_KEY} (platform-wide)"
        next [ "#{head}: unreadable value, left in place (needs SQL)" ] if source[:rows].nil?

        [ head ] + source[:rows].map do |r|
          detail = r.module_id ? "#{r.module_id} #{r.module_name.inspect} owned by account #{r.owner_account_id}" : "no such module"
          "  #{r.entry.inspect} -> #{detail} => #{r.disposition}"
        end
      end
    end

    def initialize(discard_unresolved: false, actor: nil)
      @discard = discard_unresolved
      @actor = actor
    end

    def call
      apply(plan)
    rescue StandardError => e
      ::Rails.logger.error("[PrivilegedAllowlistLegacyMigration] not migrated, legacy grant left in place: #{e.class}: #{e.message}")
      Result.new(moved_ids: [], unresolved: [], legacy_remaining: true, error: "#{e.class}: #{e.message}")
    end

    # What would move and what would be kept, with nothing written. Public so
    # the rake task can show it before it writes.
    def plan
      sources = []
      self.class.legacy_accounts.find_each do |account|
        entries = normalize(account.settings[LEGACY_KEY])
        if entries.nil?
          ::Rails.logger.error("[PrivilegedAllowlistLegacyMigration] accounts.settings of #{account.id} holds an unreadable #{LEGACY_KEY}; left in place")
        end
        sources << { kind: :account, account: account, rows: entries && account_rows(entries, account) }
      end

      site = self.class.legacy_site_setting
      if site
        entries = normalize(site_entries(site))
        ::Rails.logger.error("[PrivilegedAllowlistLegacyMigration] site_settings #{LEGACY_KEY} is unreadable; left in place") if entries.nil?
        sources << { kind: :site, row: site, rows: entries && site_rows(entries) }
      end
      { sources: sources }
    end

    private

    def apply(plan)
      readable = plan[:sources].reject { |s| s[:rows].nil? }
      moving_ids = ->(source) { source[:rows].select { |r| r.disposition == :migrate }.map(&:module_id).uniq }
      all_ids = readable.flat_map(&moving_ids).uniq
      kept = readable.flat_map { |s| s[:rows].reject { |r| r.disposition == :migrate }.map(&:entry) }
      kept.each do |entry|
        ::Rails.logger.error("[PrivilegedAllowlistLegacyMigration] legacy entry #{entry.inspect} is not auto-migrated " \
                             "(names no module, or a module owned by another account); its legacy source is kept")
      end

      ::ActiveRecord::Base.transaction do
        existing = ::System::PrivilegedModuleAllowlist.configured_ids
        live = ::System::NodeModule.where(id: existing).pluck(:id).map(&:to_s)
        stale = existing - live
        added = all_ids - live
        row = write_setting((live + added).uniq, stale: stale) if added.any?
        resource = row || ::SiteSetting.find_by(key: ::System::PrivilegedModuleAllowlist::SETTING_KEY)

        readable.each do |source|
          removing = source[:rows].all? { |r| r.disposition == :migrate } || @discard
          moved_here = moving_ids.call(source) - live
          next unless moved_here.any? || removing

          audit(source, resource: resource, moved: moved_here, removing: removing, stale: (row ? stale : []))
        end

        readable.each { |source| remove_source(source) if source[:rows].all? { |r| r.disposition == :migrate } || @discard }
      end

      Result.new(moved_ids: all_ids, unresolved: kept, legacy_remaining: self.class.legacy_present?)
    end

    def remove_source(source)
      if source[:kind] == :account
        ::Account.where(id: source[:account].id).update_all([ "settings = settings - ?", LEGACY_KEY ])
      else
        source[:row].destroy
      end
    end

    def write_setting(ids, stale:)
      ::SiteSetting.set(
        ::System::PrivilegedModuleAllowlist::SETTING_KEY, ids.to_json,
        setting_type: "json", description: "Operator grant for modules declaring security.privileged=true (NodeModule ids).", is_public: false
      ).tap do
        next if stale.empty?

        ::Rails.logger.warn("[PrivilegedAllowlistLegacyMigration] dropped #{stale.size} stale (deleted-module) id(s) from the protected value while merging")
      end
    end

    # One audit row per source moved from or removed, in the audit chain. A
    # global-setting source is reported under the platform account.
    def audit(source, resource:, moved:, removing:, stale:)
      account = source[:kind] == :account ? source[:account] : ::Account.find_by(id: self.class.platform_account_id)
      return ::Rails.logger.error("[PrivilegedAllowlistLegacyMigration] no account to audit a #{source[:kind]} source under") if account.nil?

      unresolved = source[:rows].reject { |r| r.disposition == :migrate }.map(&:entry)
      resource_type, resource_id = resource ? [ "SiteSetting", resource.id ] : [ "Account", account.id ]
      ::AuditLog.create!(
        account: account,
        user: @actor,
        action: "update_site_setting",
        resource_type: resource_type,
        resource_id: resource_id,
        source: "system",
        severity: "high",
        risk_level: "high",
        metadata: {
          setting_key: ::System::PrivilegedModuleAllowlist::SETTING_KEY,
          setting_type: "json",
          actor: @actor ? "operator" : self.class.name,
          operator_id: @actor&.id,
          migrated_from: [ source[:kind] == :account ? "accounts.settings" : "site_settings.#{LEGACY_KEY}" ],
          migrated_module_ids: moved,
          unresolved_entries: unresolved,
          unresolved_discarded: @discard && unresolved.any?,
          legacy_source_removed: removing,
          dropped_stale_ids: stale
        }.compact
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

    # An account-settings entry migrates only when it names a module that
    # account OWNS. A module of another account, or none, is kept.
    def account_rows(entries, account)
      entries.map do |entry|
        mod = if entry.match?(UUID_FORMAT)
                ::System::NodeModule.find_by(id: entry)
        else
                ::System::NodeModule.find_by(account_id: account.id, name: entry) ||
                  ::System::NodeModule.where.not(account_id: account.id).find_by(name: entry)
        end
        next PlanRow.new(entry: entry, disposition: :unknown) if mod.nil?

        PlanRow.new(entry: entry, module_id: mod.id.to_s, module_name: mod.name, owner_account_id: mod.account_id,
                    disposition: mod.account_id == account.id ? :migrate : :foreign)
      end
    end

    # The global SiteSetting was platform-level: every module it names, in any
    # account, migrates.
    def site_rows(entries)
      entries.flat_map do |entry|
        mods = entry.match?(UUID_FORMAT) ? ::System::NodeModule.where(id: entry) : ::System::NodeModule.where(name: entry)
        next [ PlanRow.new(entry: entry, disposition: :unknown) ] if mods.empty?

        mods.map do |mod|
          PlanRow.new(entry: entry, module_id: mod.id.to_s, module_name: mod.name, owner_account_id: mod.account_id, disposition: :migrate)
        end
      end
    end
  end
end
