# frozen_string_literal: true

namespace :system do
  namespace :storage do
    desc "SMB credential rotation preflight — READ-ONLY report of every SMB backend/gateway instance: " \
         "whether its agent can resolve the CredentialRef payload a rotation dispatches, and whether it " \
         "serves more than one account. Fleet-wide (all accounts). Rotates nothing and writes nothing. " \
         "Usage: rails system:storage:smb_rotation_preflight (FORMAT=json for the structured report). " \
         "Exits 1 unless the verdict is safe_to_rotate or there are no SMB backends."
    task smb_rotation_preflight: :environment do
      report = ::System::Storage::SmbRotationPreflight.call
      exit_code = report.safe_to_rotate? || report.verdict == "no_smb_backends" ? 0 : 1

      if ENV["FORMAT"] == "json"
        puts JSON.pretty_generate(report.as_json)
        exit(exit_code)
      end

      floors = report.floors
      puts "=== SMB credential rotation preflight — #{report.generated_at.iso8601} ==="
      puts "agent floor: CredentialRef-aware agent, commit #{floors[:credential_ref][:sha]} (#{floors[:credential_ref][:date]})"
      puts "             payload validation, commit #{floors[:payload_validation][:sha]} (#{floors[:payload_validation][:date]})"
      puts "             decided from the stamped agent_version \"<build date>-<sha>\"; basis=build_date means " \
           "built after the commit existed, not proven to contain it"
      puts

      puts "--- backend instances (#{report.nodes.size}) ---"
      report.nodes.each do |row|
        puts "  [#{row.status.upcase}] instance=#{row.instance_id} (#{row.instance_name}) node=#{row.node_name} " \
             "roles=#{row.roles.join(',')} status=#{row.instance_status}"
        puts "      agent:    #{row.agent_check.status} — #{row.agent_check.reason} (basis=#{row.agent_check.basis}) " \
             "version=#{row.agent_version.inspect} last_heartbeat=#{row.last_heartbeat_at&.iso8601 || 'never'}"
        puts "      accounts: #{row.account_check.status} — #{row.account_check.reason} " \
             "instance_account=#{row.instance_account_id} serves=" \
             "#{row.accounts.map { |account| "#{account[:id]} (#{account[:name]})" }.join(', ')}"
        row.storages.each do |storage|
          puts "      storage=#{storage[:id]} (#{storage[:name]}) account=#{storage[:account_id]} shape=#{storage[:deployment_shape]}"
        end
      end
      puts

      puts "--- SMB storages with no resolvable backend instance (#{report.unresolved_storages.size}) ---"
      report.unresolved_storages.each do |storage|
        puts "  [#{storage[:status].upcase}] storage=#{storage[:id]} (#{storage[:name]}) account=#{storage[:account_id]} " \
             "(#{storage[:account_name]}) backend_instance=#{storage[:backend_instance_id] || 'none'} — #{storage[:reason]}"
      end
      puts

      summary = report.summary
      puts "smb_storages=#{summary[:smb_storages]} nodes=#{summary[:nodes]} pass=#{summary[:pass]} " \
           "fail=#{summary[:fail]} unknown=#{summary[:unknown]} unresolved_storages=#{summary[:unresolved_storages]}"
      label = {
        "safe_to_rotate" => "SAFE TO ROTATE — every backend is a proven pass on both checks.",
        "not_safe" => "NOT SAFE — at least one check failed; do not rotate.",
        "unknown" => "UNKNOWN — nothing failed, but at least one check could not be proven; do not rotate on this.",
        "no_smb_backends" => "NO SMB BACKENDS — there is no SMB storage, so there is nothing to rotate and nothing was proven."
      }.fetch(report.verdict)
      puts "VERDICT: #{label}"
      puts "Read-only report. Zero writes performed."

      exit(exit_code)
    end
  end
end
