# frozen_string_literal: true

# IMP-ecb2cbef7173 — the re-run path for the storage.smb_user.apply secret
# scrub. The migration 20261001120000_scrub_smb_user_apply_task_secrets runs
# once at boot and is then stamped whether or not every row was reached (a
# rescued error, or rows a concurrent transaction held locked, leave rows
# behind by design rather than crash-loop Rails). This task runs the SAME
# scrub again, as often as needed, in every environment: db:migrate:redo is
# refused on a production control plane, whose database.yml declares several
# databases, and the suffixed form does not exist on single-database dev/test.
#
# The SQL lives in the migration and nowhere else; this task loads that file
# and calls its #scrub. The dependency points one way — rake on migration —
# so the migration stays a self-contained historical artifact. This task
# never reads or writes schema_migrations.
namespace :system do
  namespace :storage do
    desc "Re-run the storage.smb_user.apply plaintext-password scrub (migration 20261001120000) — " \
         "idempotent, batched, counts only, never prints a value. Exit status: 0 nothing left, " \
         "2 candidate rows remain (locked or of a shape the rewrite cannot change), 1 the scrub aborted."
    task scrub_smb_task_secrets: :environment do
      require PowernodeSystem::Engine.root.join("db", "migrate", "20261001120000_scrub_smb_user_apply_task_secrets.rb")

      puts "=== storage.smb_user.apply secret scrub — #{Time.current.iso8601} ==="
      puts "environment=#{Rails.env} database=#{ActiveRecord::Base.connection_db_config.database}"

      # The migration reports through #say, which prints only while the
      # class-wide verbose flag is on; restore whatever it was.
      was_verbose = ActiveRecord::Migration.verbose
      ActiveRecord::Migration.verbose = true
      outcome = begin
        ScrubSmbUserApplyTaskSecrets.new.scrub
      ensure
        ActiveRecord::Migration.verbose = was_verbose
      end

      puts "scrubbed=#{outcome.scrubbed} left=#{outcome.left.nil? ? 'unknown' : outcome.left} " \
           "aborted_by=#{outcome.aborted_by || 'none'}"
      exit_code =
        if outcome.aborted_by
          puts "OUTCOME: ABORTED — the scrub stopped on #{outcome.aborted_by}; fix the cause and run this task again."
          1
        elsif outcome.left.to_i.positive?
          puts "OUTCOME: LEFTOVER — #{outcome.left} candidate row(s) still hold a plaintext value or an echo; " \
               "run this task again once no transaction holds them."
          2
        else
          puts "OUTCOME: CLEAN — no storage.smb_user.apply row holds a plaintext value or an echo this scrub can reach."
          0
        end

      # Only a non-zero status exits, so a task chained after a clean run still runs.
      exit(exit_code) unless exit_code.zero?
    end
  end
end
