# frozen_string_literal: true

# IMP-ecb2cbef7173 — SMB remediation step 2. Scrubs the plaintext SMB password
# out of historical storage.smb_user.apply System::Task rows.
#
# WHAT WAS WRITTEN, verified against history rather than remembered:
#   - Before extension commit c9eb9e72 (2026-09-19), SmbUserManager#build_payload
#     copied credential.vault_credentials["password"] into options["password"]
#     for every action, and rotate_user! added options["new_password"]. The
#     command has been named storage.smb_user.apply since the service was
#     introduced (f5d92f69); it was never renamed, so that one string is the
#     whole scope.
#   - The pre-fix agent passed the value on samba-tool's argv, and the agent's
#     ExecRunner formats a failure as
#       fmt.Errorf("%s %v: %w (output: %s)", name, args, err, output)
#     i.e. "samba-tool [user create <user> <password>]: exit status N (output:
#     ...)" or "samba-tool [user setpassword <user> --newpassword=<password>]:
#     ...". Client.Fail posts that text verbatim and
#     NodeApi::StatusController#fail_task persists it as error_message AND
#     appends {type: "failed", message: <same text>} to events. So the echo
#     lives in two columns, and samba-tool's own output can echo the value a
#     third time inside the "(output: ...)" tail.
#   - description is never written by the SMB producer. It is scrubbed here all
#     the same, by the same two arms, because the column is free text on the
#     row and the cost is one expression.
#
# HOW IT SCRUBS — one UPDATE per row, every column at once. In PostgreSQL every
# SET expression reads the row as it was before the statement, so the
# error_message / events / description rewrite can use the row's own
# options->>'password' in the same statement that overwrites options. The
# ordering hazard (scrub options first, lose the value you needed to find the
# echo) cannot occur: there is no first.
#
# Two arms, applied in this order to each text:
#   1. VALUE arm: literal replace() of the row's own password and new_password
#      (whatever characters they contain) with the sentinel. The secret never
#      leaves the database — it is read and compared inside the one statement.
#   2. PATTERN arm: regexp_replace of the two argv shapes above, for rows whose
#      options no longer carry the value (stripped by hand or by a tool that
#      only knew about options). Negated character classes, not lazy
#      quantifiers: PostgreSQL's ARE gives a whole branch the greediness of its
#      first quantified atom, so `.*?` would eat through the output tail. The
#      redacted form "[REDACTED]]: " contains a `]` the class cannot cross, so
#      the pattern never re-matches its own output. A password containing `]`
#      is beyond the pattern arm; the value arm still removes it whenever
#      options is intact.
#
# The option keys KEEP their names with the sentinel as value, so a reader can
# tell the row was scrubbed rather than wonder whether it ever carried one.
# The sentinel matches System::ShellOutputSanitizer::REDACTED (hardcoded: a
# migration must not depend on app code). The post-fix agent's own forward
# redaction writes bare REDACTED; the two are deliberately not unified, since
# the forward path no longer puts the value on argv at all.
#
# BOOT SAFETY. This runs at boot on a self-hosted control plane that cannot
# recover from a crash-looping Rails, so nothing here may raise on data it did
# not expect:
#   - options that is not a JSON object: jsonb_set / `-` raise on a scalar, and
#     `'"password"'::jsonb ? 'password'` is TRUE for a scalar, so the key arm
#     is gated on jsonb_typeof(options) = 'object'. Such rows are left as they
#     are and reported by count.
#   - events that is not a JSON array: jsonb_array_elements raises, so the
#     rewrite and the predicate are both wrapped in CASE (which, unlike AND, is
#     guaranteed to evaluate in order). Reported by count; options and
#     error_message on such a row are still scrubbed.
#   - event elements that are not objects, or whose message is not a string,
#     are carried through unchanged. Only `message` is rewritten: the failed
#     and progress writers put their text there, and `data` is {} on both.
#   - every batch is one statement with LIMIT and FOR UPDATE SKIP LOCKED, so a
#     row a running task holds is skipped, not waited on.
#   - termination is by a STRICTLY DECREASING candidate count, re-measured
#     after each batch, not by trusting that the predicate and the rewrite
#     agree. A batch that updates rows without shrinking the set, or that
#     updates none, ends the loop and the leftover count is reported.
#   - any StandardError ends the run with a message naming the exception CLASS
#     only (StatementInvalid messages embed SQL context) and returns the count
#     so far. The migration is then stamped as run; re-run it with
#     `bin/rails db:migrate:redo VERSION=20261001120000` (down is a no-op).
#
# NEVER THE VALUE. Output is counts only; the SQL is static text with constant
# binds (command, sentinel, patterns), so ActiveRecord's SQL log carries no
# row data. No backup column, no audit metadata: the point is that the
# plaintext stops existing in this table. What this does NOT reach — dead
# tuples until vacuum, WAL and archives, base backups and dumps, replicas'
# own backups, agent and request logs, the /proc cmdline exposure c9eb9e72
# recorded — is written up next to the SMB rotation preflight in
# docs/STORAGE_SUBSYSTEM.md. Rotation is the remedy; this removes the copy.
class ScrubSmbUserApplyTaskSecrets < ActiveRecord::Migration[8.1]
  # Each batch commits on its own, so an interrupted run keeps what it did
  # and the re-run picks up the rest.
  disable_ddl_transaction!

  COMMAND = "storage.smb_user.apply"
  SENTINEL = "[REDACTED]"
  BATCH_SIZE = 500

  # The two argv shapes the pre-fix agent echoed, and their redacted forms.
  # Single-quoted on purpose: these are PostgreSQL ARE patterns passed as
  # binds, and a double-quoted heredoc would turn `\[` into `[`.
  CREATE_ARGV_PATTERN = 'samba-tool \[user create ([^]\s]+) [^]]*\]: '
  CREATE_ARGV_REDACTED = 'samba-tool [user create \1 [REDACTED]]: '
  SETPW_ARGV_PATTERN = 'samba-tool \[user setpassword ([^]\s]+) --newpassword=[^]]*\]: '
  SETPW_ARGV_REDACTED = 'samba-tool [user setpassword \1 --newpassword=[REDACTED]]: '

  # Returns the number of rows rewritten, so the spec can assert that a second
  # run does nothing rather than merely rewriting identical bytes.
  def up
    total = 0
    remaining = candidate_count

    while remaining.positive?
      updated = scrub_batch
      total += updated
      left = candidate_count
      break if updated.zero? || left >= remaining

      remaining = left
    end

    report(total: total, left: candidate_count)
    total
  rescue StandardError => e
    # Class only. The message of a StatementInvalid carries the statement and
    # can carry row context; neither belongs in a boot log.
    line = "#{self.class.name}: scrub aborted by #{e.class.name} after #{total} row(s); " \
           "re-run with bin/rails db:migrate:redo VERSION=#{redo_version}"
    say line
    Rails.logger.error(line)
    total
  end

  # Deliberately a no-op. The plaintext was overwritten in place and there is
  # nothing to restore it from; a no-op down also makes db:migrate:redo the
  # re-run path after a rescued failure or a locked-row skip.
  def down
    say "#{self.class.name}: irreversible by design; nothing to undo"
  end

  private

  # $1 command, $2 sentinel, $3 create pattern, $4 setpassword pattern,
  # $5 create replacement, $6 setpassword replacement. Constants only, never
  # row data. The predicate uses the first four; PostgreSQL refuses a bind
  # list longer than the statement references, so the count passes just those.
  PREDICATE_BINDS = [ COMMAND, SENTINEL, CREATE_ARGV_PATTERN, SETPW_ARGV_PATTERN ].freeze
  REWRITE_BINDS = (PREDICATE_BINDS + [ CREATE_ARGV_REDACTED, SETPW_ARGV_REDACTED ]).freeze

  # One batch: rewrite up to BATCH_SIZE candidate rows, all columns at once.
  def scrub_batch
    sql = <<~SQL.squish
      UPDATE system_tasks AS t SET
        options = #{scrubbed_options_sql},
        error_message = #{redacted_sql('t.error_message')},
        description = #{redacted_sql('t.description')},
        events = #{scrubbed_events_sql}
      WHERE t.id IN (
        SELECT id FROM system_tasks
        WHERE #{candidate_sql}
        LIMIT #{BATCH_SIZE}
        FOR UPDATE SKIP LOCKED
      )
    SQL

    connection.exec_update(sql, "scrub_smb_user_apply_task_secrets", REWRITE_BINDS).to_i
  end

  def candidate_count
    connection.select_value(
      "SELECT count(*) FROM system_tasks WHERE #{candidate_sql}",
      "scrub_smb_user_apply_task_secrets_count", PREDICATE_BINDS
    ).to_i
  end

  # A row is a candidate while it still holds something one of the two arms
  # can change. Each arm's predicate goes false once that arm has run, which
  # is what makes the second run touch nothing.
  def candidate_sql
    <<~SQL.squish
      command = $1
      AND (
        (jsonb_typeof(options) = 'object' AND (
             (options ? 'password' AND options ->> 'password' IS DISTINCT FROM $2)
          OR (options ? 'new_password' AND options ->> 'new_password' IS DISTINCT FROM $2)))
        OR error_message ~ $3 OR error_message ~ $4
        OR description ~ $3 OR description ~ $4
        OR CASE WHEN jsonb_typeof(events) = 'array' THEN EXISTS (
             SELECT 1 FROM jsonb_array_elements(events) AS e
             WHERE jsonb_typeof(e) = 'object' AND jsonb_typeof(e -> 'message') = 'string'
               AND (e ->> 'message' ~ $3 OR e ->> 'message' ~ $4))
           ELSE false END
      )
    SQL
  end

  # Keep each secret key the row has, with the sentinel as its value. Rows
  # whose options is not an object are not candidates on this arm and are
  # passed through unchanged.
  def scrubbed_options_sql
    <<~SQL.squish
      CASE WHEN jsonb_typeof(t.options) = 'object' THEN
        CASE WHEN t.options ? 'new_password' THEN
          jsonb_set(
            CASE WHEN t.options ? 'password' THEN jsonb_set(t.options, '{password}', to_jsonb($2::text)) ELSE t.options END,
            '{new_password}', to_jsonb($2::text))
        WHEN t.options ? 'password' THEN jsonb_set(t.options, '{password}', to_jsonb($2::text))
        ELSE t.options END
      ELSE t.options END
    SQL
  end

  # Value arm (both secrets, literal replace, skipped when the value is absent
  # or empty — replace() with an empty needle is a no-op but is not worth
  # relying on), then the pattern arm for both argv shapes. NULL in, NULL out.
  def redacted_sql(text)
    value_arm = text
    %w[password new_password].each do |key|
      value_arm = <<~SQL.squish
        CASE WHEN COALESCE(t.options ->> '#{key}', '') <> ''
             THEN replace(#{value_arm}, t.options ->> '#{key}', $2::text)
             ELSE #{value_arm} END
      SQL
    end
    "regexp_replace(regexp_replace(#{value_arm}, $3, $5, 'g'), $4, $6, 'g')"
  end

  # Rebuild the events array in order, rewriting only an object element's
  # string `message`. Non-array events pass through; an empty array stays [].
  def scrubbed_events_sql
    <<~SQL.squish
      CASE WHEN jsonb_typeof(t.events) = 'array' THEN COALESCE((
        SELECT jsonb_agg(
          CASE WHEN jsonb_typeof(e) = 'object' AND jsonb_typeof(e -> 'message') = 'string'
               THEN jsonb_set(e, '{message}', to_jsonb(#{redacted_sql("(e ->> 'message')")}))
               ELSE e END
          ORDER BY ord)
        FROM jsonb_array_elements(t.events) WITH ORDINALITY AS x(e, ord)
      ), '[]'::jsonb)
      ELSE t.events END
    SQL
  end

  def report(total:, left:)
    skipped_options = count_where("jsonb_typeof(options) <> 'object'")
    skipped_events = count_where("jsonb_typeof(events) <> 'array'")

    if total.zero? && left.zero? && skipped_options.zero? && skipped_events.zero?
      say "#{self.class.name}: no #{COMMAND} row carried a plaintext SMB password or an echo of one; nothing to scrub"
      return
    end

    say "#{self.class.name}: scrubbed #{total} #{COMMAND} row(s)"
    say "#{self.class.name}: #{skipped_options} row(s) left as they are because options is not a JSON object" if skipped_options.positive?
    say "#{self.class.name}: events left untouched on #{skipped_events} row(s) because events is not a JSON array" if skipped_events.positive?
    return unless left.positive?

    say "#{self.class.name}: #{left} candidate row(s) not scrubbed (locked by a concurrent transaction, " \
        "or of a shape the rewrite cannot change); re-run with bin/rails db:migrate:redo VERSION=#{redo_version}"
  end

  # `version` is set by the migrator, not by `new`; fall back to the file's own.
  def redo_version
    version || File.basename(__FILE__)[/\A\d+/]
  end

  def count_where(predicate)
    connection.select_value(
      "SELECT count(*) FROM system_tasks WHERE command = $1 AND #{predicate}",
      "scrub_smb_user_apply_task_secrets_count", [ COMMAND ]
    ).to_i
  end
end
