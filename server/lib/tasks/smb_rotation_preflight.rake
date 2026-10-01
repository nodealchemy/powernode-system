# frozen_string_literal: true

namespace :system do
  namespace :storage do
    desc "SMB credential rotation preflight — READ-ONLY report of every SMB backend/gateway instance: " \
         "whether its agent can take the payload a rotation dispatches, and whether it serves more than " \
         "one account. Fleet-wide (all accounts, every SMB storage whatever its status). Rotates nothing " \
         "and writes nothing. Usage: rails system:storage:smb_rotation_preflight (FORMAT=json for the " \
         "structured report). Exit status: 0 safe_to_rotate, 2 no SMB storage found (check the database), " \
         "1 anything else."
    task smb_rotation_preflight: :environment do
      report = ::System::Storage::SmbRotationPreflight.call
      exit_code = { "safe_to_rotate" => 0, "no_smb_backends" => 2 }.fetch(report.verdict, 1)

      if ENV["FORMAT"] == "json"
        puts JSON.pretty_generate(report.as_json)
      else
        floors = report.floors
        puts "=== SMB credential rotation preflight — #{report.generated_at.iso8601} ==="
        puts "environment=#{report.environment} database=#{report.database}"
        puts "scope: Every SMB storage is scanned, whatever its status and whether or not it has credentials — " \
             "a credential issued between this preflight and the rotation lands on the same backend agent."
        puts "agent floor: #{floors[:credential_ref][:sha]} resolves the CredentialRef payload and " \
             "#{floors[:stdin_delivery][:sha]} keeps the value off argv (both #{floors[:credential_ref][:date]}); " \
             "#{floors[:payload_validation][:sha]} (#{floors[:payload_validation][:date]}) added payload validation."
        puts "             Decided from the stamped agent_version \"<build date>-<sha>\". basis=build_date means built " \
             "after those commits existed: sound for a build from the default branch, not for a branch build."
        puts

        puts "--- backend instances (#{report.nodes.size}) ---"
        report.nodes.each do |row|
          puts "  [#{row.status.upcase}] instance=#{row.instance_id} (#{row.instance_name}) node=#{row.node_name} " \
               "roles=#{row.roles.join(',')} status=#{row.instance_status}"
          puts "      agent:    #{row.agent_check.status} — #{row.agent_check.reason} (basis=#{row.agent_check.basis}) " \
               "version=#{row.agent_version.inspect} last_heartbeat=#{row.last_heartbeat_at&.iso8601 || 'never'}"
          puts "                hint: #{row.agent_check.hint}" if row.agent_check.hint
          puts "      accounts: #{row.account_check.status} — #{row.account_check.reason} " \
               "instance_account=#{row.instance_account_id} serves=" \
               "#{row.accounts.map { |account| "#{account[:id]} (#{account[:name]})" }.join(', ')}"
          puts "                hint: #{row.account_check.hint}" if row.account_check.hint
          row.storages.each do |storage|
            puts "      storage=#{storage[:id]} (#{storage[:name]}) account=#{storage[:account_id]} " \
                 "status=#{storage[:status]} shape=#{storage[:deployment_shape]}"
          end
        end
        puts

        puts "--- SMB storages with no resolvable backend instance (#{report.unresolved_storages.size}) ---"
        report.unresolved_storages.each do |storage|
          puts "  [#{storage[:check].upcase}] storage=#{storage[:id]} (#{storage[:name]}) account=#{storage[:account_id]} " \
               "(#{storage[:account_name]}) status=#{storage[:status]} " \
               "backend_instance=#{storage[:backend_instance_id] || 'none'} — #{storage[:reason]}"
          puts "      hint: #{storage[:hint]}"
        end
        puts

        puts "--- agent source shas seen (#{report.agent_shas.size}) ---"
        puts "  To settle a basis=build_date pass, run in an extension checkout (exit 0 = contains the floor):"
        report.agent_shas.each do |sha|
          puts "    #{::System::Storage::SmbRotationPreflight::ANCESTRY_COMMAND.sub('<sha>', sha)}"
        end
        puts

        summary = report.summary
        puts "smb_storages=#{summary[:smb_storages]} nodes=#{summary[:nodes]} nodes_pass=#{summary[:nodes_pass]} " \
             "nodes_fail=#{summary[:nodes_fail]} nodes_unknown=#{summary[:nodes_unknown]} " \
             "unresolved_storages=#{summary[:unresolved_storages]}"
        label = {
          "safe_to_rotate" => "SAFE TO ROTATE — every backend passes both checks (see basis per row).",
          "not_safe" => "NOT SAFE — at least one check failed; do not rotate.",
          "unknown" => "UNKNOWN — nothing failed, but at least one check could not be decided; do not rotate on this.",
          "no_smb_backends" => "NO SMB BACKENDS — no SMB storage in database #{report.database}; nothing was checked. " \
                               "Confirm this is the intended database."
        }.fetch(report.verdict)
        puts "VERDICT: #{label}"
        puts "Read-only report. Zero writes performed."
      end

      # Only a non-zero status exits, so a task chained after a safe verdict still runs.
      exit(exit_code) unless exit_code.zero?
    end
  end
end
