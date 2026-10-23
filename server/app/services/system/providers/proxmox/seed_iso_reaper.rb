# frozen_string_literal: true

module System
  module Providers
    module Proxmox
      # Finds (and, with apply: true, deletes) orphaned NoCloud seed ISOs
      # (`cidata-<vmid>-<key>.iso`) on the cidata storage. IMP-b7683fab758c.
      #
      # vmids are reused across builds, so a file is kept ONLY when its exact
      # (vmid, platform-issued key) belongs to a live (non-terminated) instance:
      # a file whose vmid is live but carries an older key IS an orphan. An
      # instance with no cloud id yet (mid-provision) protects its key whatever
      # the vmid. Files younger than the grace window and names that do not match
      # the current `cidata-<vmid>-<12 hex>.iso` shape are left alone. Never reads,
      # logs or prints ISO contents; deletes one at a time, each audited through
      # the seed-cleanup audit action.
      class SeedIsoReaper
        NAME = /\Acidata-(?<vmid>\d+)-(?<key>[0-9a-f]{12})\.iso\z/
        DEFAULT_GRACE = 6.hours

        Result = Struct.new(:orphans, :deleted, :failed, :kept_live, :kept_young, :unrecognised, keyword_init: true)

        def initialize(provider:, connection:, apply: false, grace: DEFAULT_GRACE, now: Time.current)
          @provider = provider
          @connection = connection
          @apply = apply
          @grace = grace
          @now = now
        end

        def call
          result = Result.new(orphans: [], deleted: [], failed: [], kept_live: 0, kept_young: 0, unrecognised: 0)
          live = live_keys
          @provider.list_cidata_isos.each do |entry|
            m = NAME.match(entry[:filename].to_s)
            (result.unrecognised += 1; next) unless m
            (result.kept_live += 1; next) if live[:exact].include?(entry[:filename]) || live[:keys].include?(m[:key])
            (result.kept_young += 1; next) if entry[:ctime].to_i > (@now - @grace).to_i

            result.orphans << entry
          end
          result.orphans.sort_by! { |e| [ e[:ctime].to_i, e[:filename] ] }
          reap(result) if @apply
          result
        end

        private

        def live_keys
          exact = Set.new
          keys = Set.new
          ::System::NodeInstance.where.not(status: "terminated").find_each do |inst|
            key = ::System::Providers::ProxmoxProvider.seed_discriminator_for(inst)
            next if key.blank?

            vmid = inst.cloud_instance_id.to_s.split("/").last
            if vmid.present?
              exact << "cidata-#{vmid}-#{key}.iso"
            else
              keys << key
            end
          end
          { exact: exact, keys: keys }
        end

        def reap(result)
          result.orphans.each do |entry|
            @provider.delete_cidata_iso_file(node: entry[:node], filename: entry[:filename])
            result.deleted << entry
            audit(entry)
          rescue StandardError => e
            Rails.logger.warn("[SeedIsoReaper] delete failed: #{e.class}")
            result.failed << entry
          end
        end

        def audit(entry)
          ::AuditLog.log_action(
            action: ::System::EnrollmentSeedCleanup::AUDIT_ACTION,
            resource: @connection,
            account: @connection.account,
            source: "system",
            metadata: { "outcome" => "reaped_orphan_iso", "provider_type" => "proxmox",
                        "note" => "deleted orphaned seed #{entry[:filename]} on #{entry[:node]}" }
          )
        rescue StandardError => e
          Rails.logger.warn("[SeedIsoReaper] audit write failed: #{e.class}")
        end
      end
    end
  end
end
