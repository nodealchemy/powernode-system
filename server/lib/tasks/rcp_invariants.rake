# frozen_string_literal: true

# RCP v2 (campaign 019f9250, increment p0c) — operator entry points for the
# INV-1/2/6 fleet-wide scan. MUST be run from a live deployment with real
# provider credentials (e.g. `cd /opt/powernode/server && bundle exec rails
# rcp:invariant_scan`) — NOT from a worktree checkout, where Rails
# credentials do not decrypt (see the "Worktree runner credential decrypt
# EMPTY" operational note). The static (non-live) scan still works from any
# context with DB access; only `live=true` needs real Proxmox credentials.
namespace :rcp do
  desc "RCP v2 INV-1/2/6 fleet-wide scan. Usage: rails rcp:invariant_scan[account_id] LIVE=1 (LIVE opts into a real Proxmox list_volume_types call per instance for a confirmed INV-6 answer; omit for a fast static/DB-only pass)"
  task :invariant_scan, [ :account_id ] => :environment do |_t, args|
    account = if args[:account_id].present?
                Account.find(args[:account_id])
    else
                Account.first
    end

    unless account
      puts "No account found — nothing to scan."
      next
    end

    live = ActiveModel::Type::Boolean.new.cast(ENV["LIVE"])
    result = System::Compliance::RcpInvariantScanner.scan(account: account, live: live)

    puts "RCP invariant scan — account #{account.id} (#{account.name}) — live=#{result.live} — #{result.scanned_at.iso8601}"
    puts "=" * 100

    [ [ "INV-1 (no self-management)", result.inv1 ],
      [ "INV-2 (no boot-time network dependency)", result.inv2 ],
      [ "INV-6 (member storage local, no shared NFS root)", result.inv6 ] ].each do |label, findings|
      puts "\n#{label}: #{findings.size} finding(s)"
      findings.each do |f|
        puts "  - node=#{f[:node_id]} instance=#{f[:instance_id]} severity=#{f[:severity]} verified=#{f[:verified]}"
        puts "    #{f[:detail]}"
      end
    end

    puts "\n#{'=' * 100}"
    puts result.clean? ? "CLEAN — no violations found." : "#{result.violations.size} total finding(s) — see above."
    puts "(static pass — INV-6 findings are unverified against live Proxmox; re-run with LIVE=1 to confirm)" unless live
  end

  desc "Live-only: resolve a Node's provider connection and print its Proxmox storage.cfg pool types (plugintype/shared) for one PVE cluster member. Usage: rails rcp:storage_topology[node_name,pve_node_name] — e.g. rcp:storage_topology[ops-hub,rna] to independently confirm rna's local-data zpool is NOT shared/nfs, the way this campaign's INV-6 ground truth for dna-data was confirmed for dna."
  task :storage_topology, [ :node_name, :pve_node_name ] => :environment do |_t, args|
    node = System::Node.find_by!(name: args[:node_name])
    instance = node.node_instances.where(status: %w[running starting pending]).first ||
               node.node_instances.order(created_at: :desc).first

    unless instance&.provider_region
      puts "Node #{node.name} has no instance with a resolvable provider_region — cannot resolve a provider adapter."
      next
    end

    adapter = System::Providers::Registry.for_instance(instance)
    unless adapter.respond_to?(:list_volume_types)
      puts "Adapter #{adapter.class} does not support list_volume_types (non-Proxmox provider) — nothing to check."
      next
    end

    pve_node = args[:pve_node_name].presence || instance.provider_region&.name
    puts "Querying live PVE storage.cfg on node '#{pve_node}' via #{node.name}'s resolved provider connection..."
    pools = adapter.list_volume_types(pve_node)

    puts "\n#{'storage'.ljust(20)} #{'plugin_type'.ljust(14)} shared  content"
    pools.each do |p|
      puts "#{p[:name].to_s.ljust(20)} #{p[:plugin_type].to_s.ljust(14)} #{p[:shared] ? 'yes' : 'no'.ljust(6)}  #{Array(p[:content_types]).join(',')}"
    end

    network_pools = pools.select { |p| System::Autonomy::StorageLocalityCheck::NETWORK_PLUGIN_TYPES.include?(p[:plugin_type].to_s) }
    puts "\nNetwork-backed (NFS/CIFS) pools on #{pve_node}: #{network_pools.map { |p| p[:name] }.join(', ').presence || 'none'}"
  end
end
