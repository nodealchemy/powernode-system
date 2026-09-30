# frozen_string_literal: true

module System
  # The operator's GRANT for modules that declare security.privileged=true.
  #
  # A module manifest can only REQUEST privileged (all on-node confinement off);
  # the agent refuses to attach it, and at pivot compose refuses to enable its
  # services, unless the node API lists its id in privileged_module_ids. That
  # list is this setting. It is PROTECTED: registering it that way is the whole
  # point (IMP-06cf44531256), because before it the only way to grant it was a
  # direct SQL write to accounts.settings, which left no audit trail. Now the
  # only write door is the human-only site_setting_set_protected, which parks
  # for a person to confirm in their own session and records who did it.
  #
  # NOT machine-parkable, deliberately. dev_merge.private_extension_names and
  # system.ssh.require_host_key let an instance ASK; this one does not. The
  # module an instance would ask to have unconfined is very often the module the
  # instance itself runs (dev-cell), so a request would be a self-grant awaiting
  # a click, and the approval card shows bare UUIDs a person cannot tell apart.
  # The grant is initiated by a person, in the settings surface, naming the
  # module they mean.
  #
  # The value is a JSON list of NodeModule ids. Ids only, never names: the agent
  # keys its gate on the immutable server-assigned id, and a name is mutable and
  # author-influenced (finding F1 on the original gate). Existence is checked
  # across accounts because a SiteSetting is global and a value check sees no
  # account; a foreign-account id is inert regardless, since the node API only
  # ever emits ids of modules resolved for THIS node.
  module PrivilegedModuleAllowlist
    SETTING_KEY = "system.privileged_module_ids"

    UUID_FORMAT = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

    # A fleet event per (instance, module) at most this often, so a node polling
    # the modules endpoint every few seconds does not write a row per poll.
    UNAPPROVED_EVENT_KIND = "system.privileged_module_unapproved"
    UNAPPROVED_EVENT_INTERVAL = 1.hour

    # Kept alive, critical, for as long as a legacy source of the grant remains
    # after the migration ran: the setting above is the ONLY source the reader
    # honours, so a grant stranded in accounts.settings is a grant that is not in
    # force. See System::PrivilegedAllowlistLegacyMigration.
    LEGACY_PENDING_EVENT_KIND = "system.privileged_allowlist_migration_pending"

    module_function

    # Ids the operator has granted, as strings. [] when unset (deny), and [] when
    # the stored value is not a list of strings: an unreadable grant is no grant.
    def configured_ids
      row = ::SiteSetting.find_by(key: SETTING_KEY)
      return [] if row.nil?

      parsed = parse(row.value)
      return parsed if parsed

      ::Rails.logger.error("[PrivilegedModuleAllowlist] #{SETTING_KEY} is not a JSON list of strings; treating as empty (deny)")
      []
    end

    # The registered value check: nil when acceptable, else the reason.
    def declaration_problem(value)
      ids = parse(value)
      return "must be a JSON list of NodeModule ids (strings), for example [\"<module id>\"]; [] grants none" if ids.nil?

      malformed = ids.reject { |id| id.match?(UUID_FORMAT) }
      unless malformed.empty?
        return "entries must be NodeModule ids (UUIDs), not names; #{malformed.size} entr#{malformed.size == 1 ? 'y is' : 'ies are'} not a module id"
      end

      known = ::System::NodeModule.where(id: ids).pluck(:id).map(&:to_s)
      missing = ids - known
      return nil if missing.empty?

      "#{missing.size} entr#{missing.size == 1 ? 'y names' : 'ies name'} no existing NodeModule: #{missing.first(3).join(', ')}"
    end

    # The approval card's reading of the value (IMP-78bc3b20ee94): each id with
    # its module's name and OWNING ACCOUNT beside it, so a person can tell the
    # bare UUIDs apart. Registered on core's SiteSetting.register_value_presenter
    # seam, which runs it read-only under a statement timeout, shows it NEXT TO
    # the raw value and only to an admin.access holder, and falls back to the raw
    # value if this raises.
    #
    # STRUCTURED, not a sentence: each item is the raw id, the module `name` and
    # `owner` as separate fields (tenant text, sanitized by core, labelled by the
    # client), and flags this code computes from ids and account ids, never from
    # text: `unknown` (no such module now: deleted, or not a module id) and
    # `other_account` (the module belongs to an account other than the viewer's).
    #
    # Read live, at render time: a deleted module is flagged, a rename shows the
    # current name. One query for at most PRESENTED_ROW_LIMIT ids (the rest are
    # counted as `omitted`, raw only). Only the module name and the owner's name
    # are read, nothing else about a module or an account, and foreign accounts'
    # modules are included on purpose (the setting is global; the operator is
    # unconfining a module wherever it lives).
    def present(value, viewer = nil)
      ids = parse(value)
      return nil if ids.nil?

      shown = ids.first(::SiteSetting::PRESENTED_ROW_LIMIT)
      found = ::System::NodeModule.where(id: shown.grep(UUID_FORMAT)).joins(:account)
                                  .pluck(:id, :name, :account_id, "accounts.name")
                                  .to_h { |id, name, account_id, owner| [ id.to_s, [ name, account_id, owner ] ] }
      viewer_account_id = viewer.respond_to?(:account_id) ? viewer.account_id : nil
      items = shown.map do |id|
        name, account_id, owner = found[id]
        next { raw: id, fields: {}, flags: [ "unknown" ] } if account_id.nil?

        { raw: id, fields: { name: name, owner: owner },
          flags: account_id.to_s == viewer_account_id.to_s ? [] : [ "other_account" ] }
      end
      { items: items, omitted: ids.size - shown.size }
    end

    # An Array<String>, or nil when `value` is not a JSON list of strings.
    def parse(value)
      list = value.is_a?(String) ? JSON.parse(value) : value
      return nil unless list.is_a?(Array) && list.all?(String)

      list.map(&:strip).reject(&:blank?).uniq
    rescue JSON::ParserError
      nil
    end

    # The module ids on this node that declare security.privileged=true and are
    # not granted. The agent refuses each of them (at attach, and at compose it
    # leaves their services disabled), so without this the operator's first sign
    # is a module that simply is not running.
    def unapproved_privileged(resolved_modules, approved_ids)
      approved = approved_ids.to_set
      resolved_modules.select do |mod|
        security = mod.config.is_a?(Hash) ? mod.config["security"] : nil
        security.is_a?(Hash) && security["privileged"] == true && !approved.include?(mod.id.to_s)
      end
    end

    # Make the refusal visible: a high-severity fleet event naming the module and
    # the instance, so the operator sees "module X wants privileged and is not
    # granted" instead of a node whose services quietly stayed off. Never raises
    # into the node API poll it rides on.
    def report_unapproved!(account:, instance:, modules:)
      modules.each do |mod|
        next if recently_reported?(instance, mod)

        ::System::Fleet::EventBroadcaster.emit!(
          account: account,
          kind: UNAPPROVED_EVENT_KIND,
          severity: :high,
          payload: { "module_name" => mod.name.to_s, "setting_key" => SETTING_KEY,
                     "remedy" => "an operator grants the module id through the protected site setting #{SETTING_KEY}" },
          source: "node_api.modules",
          node_instance_id: instance&.id,
          node_module_id: mod.id
        )
      end
    rescue StandardError => e
      ::Rails.logger.warn("[PrivilegedModuleAllowlist] could not report unapproved privileged modules: #{e.class}: #{e.message}")
    end

    # The reader deliberately does NOT honour a legacy source while the
    # migration is pending: that would keep an unaudited, SQL-only privilege path
    # live exactly when the move has failed, and a stuck failure would make the
    # dual source permanent. The cost of not honouring it is a visible refusal,
    # so make that loud instead: a critical event and an ERROR log, once per
    # interval, naming the remedy. Stops by itself once the migration has moved
    # the grant. Never raises into the poll.
    def report_legacy_pending!(account:, instance:)
      return unless ::System::PrivilegedAllowlistLegacyMigration.legacy_present_for?(account)
      return if ::System::FleetEvent.by_kind(LEGACY_PENDING_EVENT_KIND).where(account_id: account&.id)
                                    .where("emitted_at >= ?", UNAPPROVED_EVENT_INTERVAL.ago).exists?

      ::Rails.logger.error(
        "[PrivilegedModuleAllowlist] a legacy privileged_module_ids grant is still present and NOT in force; " \
        "run: rake system:privileged_allowlist:migrate_legacy (prints the plan; CONFIRM=1 OPERATOR=<user> applies it)"
      )
      ::System::Fleet::EventBroadcaster.emit!(
        account: account,
        kind: LEGACY_PENDING_EVENT_KIND,
        severity: :critical,
        payload: { "setting_key" => SETTING_KEY,
                   "remedy" => "run rake system:privileged_allowlist:migrate_legacy to see the plan, CONFIRM=1 OPERATOR=<user> to apply it (or grant the module ids through the protected site setting #{SETTING_KEY}); an unreadable legacy value needs SQL" },
        source: "node_api.modules",
        node_instance_id: instance&.id
      )
    rescue StandardError => e
      ::Rails.logger.warn("[PrivilegedModuleAllowlist] could not check for a pending legacy grant: #{e.class}: #{e.message}")
    end

    def recently_reported?(instance, mod)
      ::System::FleetEvent.by_kind(UNAPPROVED_EVENT_KIND)
                          .where(node_instance_id: instance&.id, node_module_id: mod.id)
                          .where("emitted_at >= ?", UNAPPROVED_EVENT_INTERVAL.ago).exists?
    end
  end
end
