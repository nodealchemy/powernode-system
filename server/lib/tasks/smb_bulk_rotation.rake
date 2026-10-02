# frozen_string_literal: true

# IMP-2ceb2bd37e71 — OPERATOR-RUN bulk rotation of every live SMB credential.
# See System::Storage::SmbBulkRotation and docs/STORAGE_SUBSYSTEM.md. The dev loop
# ships these tasks; it never runs them against a live environment.
namespace :system do
  namespace :storage do
    desc "Rotate EVERY live SMB credential (operator-run). DRY RUN by default: states the count and " \
         "rotates nothing. To execute, re-run with CONFIRM=<the count the dry run printed>; execution is " \
         "refused unless the preflight (system:storage:smb_rotation_preflight) is safe_to_rotate. " \
         "SINCE=<ISO8601 with zone> resumes an interrupted run by skipping credentials already rotated at or " \
         "after it. LIMIT=<n> rotates only the first n (a pilot: rotate one, verify it converged, then the rest). " \
         "Stops at the first server-side failure. Exit: 0 ok/dry run, 1 a rotation failed, 3 refused or bad input."
    task smb_rotate_all: :environment do
      refuse = lambda do |message|
        puts "REFUSED: #{message}"
        exit(3)
      end

      since = nil
      if ENV["SINCE"].present?
        since = begin
          Time.iso8601(ENV["SINCE"])
        rescue ArgumentError
          refuse.call("SINCE=#{ENV['SINCE'].inspect} is not an ISO8601 timestamp (e.g. 2026-10-02T07:00:00Z)")
        end
        refuse.call("SINCE=#{since.utc.iso8601} is in the future; it would skip nothing") if since > Time.current
      end

      limit = nil
      if ENV["LIMIT"].present?
        refuse.call("LIMIT=#{ENV['LIMIT'].inspect} must be a positive integer") unless ENV["LIMIT"].strip.match?(/\A[1-9]\d*\z/)
        limit = ENV["LIMIT"].strip.to_i
      end

      rotation = ::System::Storage::SmbBulkRotation.new(since: since, limit: limit)
      plan = rotation.plan
      preflight = ::System::Storage::SmbRotationPreflight.call
      mode = ENV["CONFIRM"].present? ? "EXECUTE" : "DRY RUN"

      puts "=== SMB bulk credential rotation — #{mode} — #{plan.generated_at.iso8601} ==="
      puts "environment=#{Rails.env} database=#{ActiveRecord::Base.connection_db_config.database}"
      puts "preflight: #{preflight.verdict}"
      puts "since=#{since.utc.iso8601} (skipped_recent=#{plan.skipped_recent})" if since
      puts "limit=#{limit} of #{plan.total_eligible} eligible (pilot run)" if limit
      puts "EXCLUDED #{plan.excluded.size} assignment(s) the platform cannot rotate-and-remount safely " \
           "(disabled, not mounted/degraded, or no confirmed mount); handle them separately:" if plan.excluded.any?
      plan.excluded.each do |row|
        puts "  [EXCLUDED] assignment=#{row[:assignment_id]} status=#{row[:assignment_status]} reason=#{row[:reason]}"
      end
      puts "This will rotate #{plan.count} SMB credential(s)."
      shown = plan.count > 5 ? plan.rows.first(3) + [ plan.rows.last ] : plan.rows
      plan.rows.each_with_index do |row, index|
        next unless shown.include?(row)

        puts "  [#{index + 1}/#{plan.count}] assignment=#{row[:assignment_id]} account=#{row[:account_id]} " \
             "storage=#{row[:file_storage_id]} consumer_instance=#{row[:node_instance_id]} " \
             "credential=#{row[:credential_id]} last_rotated_at=#{row[:last_rotated_at] || 'never'}"
        puts "  ... #{plan.count - 4} more" if plan.count > 5 && index == 2
      end

      if ENV["CONFIRM"].blank?
        puts
        puts "Rotates nothing. #{preflight.verdict == 'safe_to_rotate' ? '' : '(An execute run would be REFUSED: the preflight is not safe_to_rotate.) '}" \
             "To execute, re-run with CONFIRM=#{plan.count}."
        next
      end

      begin
        result = rotation.execute!(confirm_count: ENV["CONFIRM"]) do |event|
          if event[:event] == "start"
            puts "started_at=#{event[:started_at].iso8601} (resume an interrupted run with SINCE=this value)"
            $stdout.flush
          else
            puts "  [#{event[:index]}/#{event[:total]}] assignment=#{event[:assignment_id]} #{event[:outcome]}"
            $stdout.flush
          end
        end
      rescue ::System::Storage::SmbBulkRotation::Refused => e
        refuse.call(e.message)
      end

      puts
      result.failed.each do |failure|
        puts "FAILED assignment=#{failure[:assignment_id]} #{failure[:error_class]} (see the server log for the message)"
      end
      puts "rotated=#{result.rotated.size} skipped=#{result.skipped.size} failed=#{result.failed.size} " \
           "not_attempted=#{result.not_attempted} " \
           "started_at=#{result.started_at.iso8601}"
      if result.failed.any?
        puts "Stopped at the first server-side failure. Fix the cause, then resume with " \
             "SINCE=#{result.started_at.iso8601} CONFIRM=<new dry-run count> to skip what already rotated."
      end
      puts "Rotation dispatches work to agents; it does not wait for them. Check convergence with " \
           "rails system:storage:smb_rotate_verify until it reports COMPLETE."
      exit(1) if result.failed.any?
    end

    desc "Verify an SMB bulk rotation (READ-ONLY, re-runnable): per consumer, whether the agent CONFIRMED " \
         "the remount onto the active credential, and whether any credential is still rotating. " \
         "Exit 0 only when COMPLETE, 1 while PENDING."
    task smb_rotate_verify: :environment do
      report = ::System::Storage::SmbBulkRotation.new.verify

      puts "=== SMB bulk rotation verification — #{report.generated_at.iso8601} ==="
      puts "environment=#{Rails.env} database=#{ActiveRecord::Base.connection_db_config.database}"
      report.excluded.each do |row|
        puts "  [EXCLUDED] assignment=#{row[:assignment_id]} status=#{row[:assignment_status]} reason=#{row[:reason]} " \
             "(not rotated by the bulk tool; handle separately)"
      end
      report.rows.reject { |row| row[:state] == "confirmed" }.each do |row|
        puts "  [#{row[:state].upcase}] assignment=#{row[:assignment_id]} consumer_instance=#{row[:node_instance_id]} " \
             "active_credential=#{row[:active_credential_id]} mounted_credential=#{row[:mounted_credential_id] || 'none'} " \
             "assignment_status=#{row[:assignment_status]}"
      end
      puts "consumers=#{report.rows.size} confirmed=#{report.counts[:confirmed]} " \
           "stale_mount=#{report.counts[:stale_mount]} " \
           "rotating=#{report.rotating} stuck_rotating=#{report.stuck_rotating} excluded=#{report.excluded.size}"
      if report.verdict == "complete"
        puts "VERDICT: COMPLETE — every consumer confirmed its remount and no credential is still rotating."
      else
        puts "VERDICT: PENDING — a mounted consumer that has not confirmed is re-dispatched by the drift sweep; " \
             "a credential left rotating is retired once its consumer confirms. Re-run this check."
        exit(1)
      end
    end
  end
end
