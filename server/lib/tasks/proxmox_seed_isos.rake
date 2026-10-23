# frozen_string_literal: true

namespace :system do
  namespace :proxmox do
    desc "Reap orphaned cidata-<vmid>-<key>.iso seed ISOs. Usage: rake system:proxmox:reap_seed_isos " \
         "[APPLY=1] [GRACE_HOURS=6]. Dry run by default; APPLY=1 deletes, one at a time, audited."
    task reap_seed_isos: :environment do
      apply = ENV["APPLY"] == "1"
      grace = (ENV["GRACE_HOURS"].presence || 6).to_f.hours
      conns = ::System::ProviderConnection.joins(:provider).where(system_providers: { provider_type: "proxmox" }).enabled
                .select { |cn| ::System::Providers::ProxmoxProvider.cidata_iso_transport_for?(cn.config) }
      puts "reap_seed_isos: #{apply ? 'APPLY' : 'DRY RUN (set APPLY=1 to delete)'}, grace #{grace.inspect}, #{conns.size} connection(s) on the ISO transport"

      conns.each do |conn|
        provider = ::System::Providers::Registry.for(conn)
        result = ::System::Providers::Proxmox::SeedIsoReaper.new(provider: provider, connection: conn, apply: apply, grace: grace).call
        shown = result.orphans.first(3) + (result.orphans.size > 3 ? [ result.orphans.last ] : [])
        puts "connection #{conn.name}: #{result.orphans.size} orphan(s); kept live=#{result.kept_live} young=#{result.kept_young} unrecognised=#{result.unrecognised}"
        puts "  first 3 and last 1:" if shown.any?
        shown.each { |e| puts "    #{e[:node]} #{e[:filename]} (#{Time.at(e[:ctime]).utc.iso8601})" }
        puts "  deleted #{result.deleted.size}, failed #{result.failed.size}" if apply
      end
    end
  end
end
