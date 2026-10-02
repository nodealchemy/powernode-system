# frozen_string_literal: true

require "rails_helper"
require Rails.root.join(
  "../extensions/system/server/db/migrate/20261001120000_scrub_smb_user_apply_task_secrets.rb"
)

# IMP-ecb2cbef7173 — SMB remediation step 2. Before extension commit c9eb9e72,
# SmbUserManager#build_payload put the SMB password into System::Task#options
# (`password`, and `new_password` on set_password), and a failed run echoed it
# back through the agent's ExecRunner error ("samba-tool [user create <user>
# <password>]: exit status N (output: ...)"), which NodeApi::StatusController
# #fail_task persisted as error_message AND mirrored into events[].message.
#
# These examples prove the PROPERTY on rows shaped exactly as those writers
# shaped them: after the migration the secret is gone from every column, the
# rest of the row survives, other commands are untouched byte for byte, a second
# run changes nothing, and rows of a shape nobody expected do not raise — this
# migration runs at boot on a control plane that cannot recover from a
# crash-looping Rails.
#
# NO REAL PAYLOAD APPEARS HERE. Every value is an obvious synthetic marker, and
# the point of the assertions is that the marker stops being present.
RSpec.describe ScrubSmbUserApplyTaskSecrets do
  subject(:migration) { described_class.new }

  let(:account)  { create(:account) }
  let(:sentinel) { described_class::SENTINEL }
  let(:command)  { described_class::COMMAND }

  let(:marker)     { "synthetic-not-a-real-smb-password-#{SecureRandom.hex(4)}" }
  let(:new_marker) { "synthetic-not-a-real-new-smb-password-#{SecureRandom.hex(4)}" }

  # The pre-fix agent's ExecRunner error, verbatim shape:
  #   fmt.Errorf("%s %v: %w (output: %s)", name, args, err, buf.String())
  # The default output carries a "]: " of its own, so a pattern that ran past
  # the argv's closing bracket would be caught eating into the output tail.
  def create_echo(user, password, output: "ERROR(ldb): Failed to add user '#{user}' [see log]: line 3")
    "samba-tool [user create #{user} #{password}]: exit status 255 (output: #{output})"
  end

  def setpw_echo(user, password, output: "ERROR: Failed to set password for user '#{user}'")
    "samba-tool [user setpassword #{user} --newpassword=#{password}]: exit status 1 (output: #{output})"
  end

  # What NodeApi::StatusController#fail_task appends.
  def failed_event(message)
    { "type" => "failed", "message" => message, "timestamp" => "2026-09-18T10:00:00Z" }
  end

  def options_for(action:, username:, **secrets)
    {
      "storage_id" => SecureRandom.uuid,
      "account_id" => account.id,
      "action" => action,
      "username" => username,
      "deployment_shape" => "backend",
      "re_share_name" => nil
    }.merge(secrets)
  end

  # Seeds a row AS THE PRE-FIX WRITERS LEFT IT. `update_columns` so no model
  # callback or validation reshapes it; the migration must clean what is
  # actually in the table, not what the model would write today.
  def task!(options:, command: self.command, error_message: nil, events: [], description: nil, status: "failed")
    task = create(:system_task, account: account, command: command, status: status)
    task.update_columns(options: options, error_message: error_message, events: events, description: description)
    task
  end

  def conn = ActiveRecord::Base.connection

  def row_text(id)
    conn.select_value("SELECT row_to_json(t)::text FROM system_tasks t WHERE id = #{conn.quote(id)}")
  end

  def table_snapshot
    conn.select_values("SELECT row_to_json(t)::text FROM system_tasks t ORDER BY id")
  end

  def rows_containing(text)
    conn.select_value("SELECT count(*) FROM system_tasks t WHERE row_to_json(t)::text LIKE #{conn.quote("%#{text}%")}").to_i
  end

  def set_raw(id, assignment)
    conn.execute("UPDATE system_tasks SET #{assignment} WHERE id = #{conn.quote(id)}")
  end

  # Runs the migration capturing what it prints and every SQL statement (text,
  # binds and type-cast binds) ActiveRecord logged while it ran. Returns the
  # migration's return value; the captures land in @printed / @sql.
  def run!
    @sql = []
    subscription = ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
      payload = args.last
      casted = payload[:type_casted_binds]
      casted = casted.call if casted.respond_to?(:call)
      @sql << [ payload[:sql], payload[:binds].inspect, casted.inspect ].join(" ")
    end
    out = StringIO.new
    original = $stdout
    $stdout = out
    # `verbose` is a class attribute on every migration; restore it after.
    was_verbose = ActiveRecord::Migration.verbose
    ActiveRecord::Migration.verbose = true
    migration.up
  ensure
    $stdout = original
    ActiveRecord::Migration.verbose = was_verbose unless was_verbose.nil?
    @printed = out.string
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
  end

  # The rescue path's boot safety depends on each batch committing on its own:
  # inside a wrapping migration transaction a rescued error would still abort
  # the transaction, and with it the boot.
  it "runs outside a wrapping transaction" do
    expect(described_class.disable_ddl_transaction).to be(true)
  end

  describe "#up" do
    context "with rows shaped as the pre-fix producer and the failed-task path wrote them" do
      let!(:create_row) do
        task!(
          options: options_for(action: "create", username: "u-create", "password" => marker),
          error_message: create_echo("u-create", marker),
          events: [
            { "type" => "progress", "message" => "Progress: 10%", "timestamp" => "2026-09-18T09:59:00Z", "data" => {} },
            failed_event(create_echo("u-create", marker))
          ]
        )
      end

      # Rotation: both the current and the new password rode along, and the
      # tool's own output can echo the value too, not only argv.
      let!(:rotate_row) do
        task!(
          options: options_for(action: "set_password", username: "u-rotate",
                               "password" => marker, "new_password" => new_marker),
          error_message: setpw_echo("u-rotate", new_marker, output: "rejected #{new_marker}: too weak"),
          events: [ failed_event(setpw_echo("u-rotate", new_marker, output: "rejected #{new_marker}: too weak")) ]
        )
      end

      # A delete never carried a secret and never echoed one. Must survive
      # untouched even though it is the same command.
      let!(:delete_row) do
        task!(options: options_for(action: "delete", username: "u-delete"), status: "complete")
      end

      # A different command carrying the SAME key names and the same echo shape.
      # Scope is the command, so this row must be byte-identical afterwards.
      let!(:unrelated_row) do
        task!(
          command: "storage.mount",
          options: { "password" => marker, "new_password" => new_marker, "mount_path" => "/mnt/x" },
          error_message: create_echo("u-other", marker),
          events: [ failed_event(create_echo("u-other", marker)) ],
          description: "mount with #{marker}"
        )
      end

      let!(:unrelated_before) { row_text(unrelated_row.id) }
      let!(:delete_before)    { row_text(delete_row.id) }

      before { run! }

      it "leaves no secret in any column of any row" do
        expect(rows_containing(marker)).to eq(1)      # only the unrelated command's row
        expect(rows_containing(new_marker)).to eq(1)  # same row
        expect(row_text(create_row.id)).not_to include(marker)
        expect(row_text(rotate_row.id)).not_to include(marker)
        expect(row_text(rotate_row.id)).not_to include(new_marker)
      end

      it "keeps the option keys with the sentinel so a reader can tell the row was scrubbed" do
        options = create_row.reload.options
        expect(options["password"]).to eq(sentinel)
        expect(options).not_to have_key("new_password")

        options = rotate_row.reload.options
        expect(options["password"]).to eq(sentinel)
        expect(options["new_password"]).to eq(sentinel)
      end

      it "preserves every non-secret option" do
        options = create_row.reload.options
        expect(options["action"]).to eq("create")
        expect(options["username"]).to eq("u-create")
        expect(options["account_id"]).to eq(account.id)
        expect(options["deployment_shape"]).to eq("backend")
        expect(options).to have_key("re_share_name")
      end

      it "redacts the argv echo in error_message by the row's own option value, keeping the rest of the message" do
        expect(create_row.reload.error_message)
          .to eq("samba-tool [user create u-create [REDACTED]]: exit status 255 (output: ERROR(ldb): Failed to add user 'u-create' [see log]: line 3)")
        expect(rotate_row.reload.error_message)
          .to eq("samba-tool [user setpassword u-rotate --newpassword=[REDACTED]]: exit status 1 (output: rejected [REDACTED]: too weak)")
      end

      it "redacts the mirrored failed event and keeps event order, types and timestamps" do
        events = create_row.reload.events
        expect(events.map { |e| e["type"] }).to eq(%w[progress failed])
        expect(events.first).to eq(
          "type" => "progress", "message" => "Progress: 10%", "timestamp" => "2026-09-18T09:59:00Z", "data" => {}
        )
        expect(events.last["message"])
          .to eq("samba-tool [user create u-create [REDACTED]]: exit status 255 (output: ERROR(ldb): Failed to add user 'u-create' [see log]: line 3)")
        expect(events.last["timestamp"]).to eq("2026-09-18T10:00:00Z")
      end

      it "does not bump updated_at: the row is the same row with the secret gone, not a new edit" do
        expect(create_row.reload.updated_at).to eq(create_row.updated_at)
      end

      it "leaves a same-command row that never carried a secret byte-identical" do
        expect(row_text(delete_row.id)).to eq(delete_before)
      end

      it "leaves another command byte-identical even when it carries the same keys and echo shape" do
        expect(row_text(unrelated_row.id)).to eq(unrelated_before)
      end

      it "prints counts only — never a value" do
        expect(@printed).to match(/scrubbed 2 /)
        expect(@printed).not_to include(marker)
        expect(@printed).not_to include(new_marker)
      end

      it "never puts a secret into the SQL it runs or the bind values ActiveRecord logs" do
        expect(@sql).not_to be_empty
        joined = @sql.join("\n")
        expect(joined).not_to include(marker)
        expect(joined).not_to include(new_marker)
      end

      it "is idempotent — a second run rewrites no rows and the table is byte-identical" do
        snapshot = table_snapshot

        expect(run!).to eq(0)

        expect(table_snapshot).to eq(snapshot)
        expect(@printed).to match(/nothing to scrub/)
      end
    end

    it "reports a positive count on the run that did the work" do
      task!(options: options_for(action: "create", username: "u", "password" => marker))

      expect(run!).to eq(1)
    end

    # The loop, not just one statement: more candidates than a batch holds
    # must all be reached, and the loop must end with none left over.
    it "walks every batch until no candidate remains" do
      stub_const("#{described_class}::BATCH_SIZE", 2)
      rows = Array.new(5) do |i|
        task!(options: options_for(action: "create", username: "u-#{i}", "password" => marker),
              error_message: create_echo("u-#{i}", marker))
      end

      expect(run!).to eq(5)

      expect(@printed).to match(/scrubbed 5 /)
      expect(@printed).not_to match(/not scrubbed/)
      expect(migration.send(:candidate_count)).to eq(0)
      rows.each { |row| expect(row_text(row.id)).not_to include(marker) }
    end

    # The value arm is literal: a password made of regex and LIKE metacharacters,
    # including the `]` the argv pattern cannot cross, is still removed because
    # the row's own option value is what is searched for. Asserted on the
    # reloaded columns, not on row_to_json text, where the backslash is
    # escaped and the raw string could never appear.
    it "redacts a password full of metacharacters, and one containing ']', through the row's own option value" do
      odd = "synthetic-]-%-_-\\-(not)-a-real-[smb]-password-#{SecureRandom.hex(4)}"
      row = task!(
        options: options_for(action: "create", username: "u-odd", "password" => odd),
        error_message: create_echo("u-odd", odd),
        events: [ failed_event(create_echo("u-odd", odd)) ]
      )

      run!

      row.reload
      expect(row.options["password"]).to eq(sentinel)
      expect(row.error_message).not_to include(odd)
      expect(row.error_message).to start_with("samba-tool [user create u-odd [REDACTED]]: exit status 255")
      expect(row.events.last["message"]).not_to include(odd)
      expect(row.events.last["message"]).to start_with("samba-tool [user create u-odd [REDACTED]]: exit status 255")
    end

    # The fallback for a row whose options no longer carry the value (scrubbed by
    # hand, or by a tool that only knew about options): the argv shape is still
    # recognisable and is redacted by pattern. Argv only — this arm cannot know
    # the value, so a repeat of it in the output tail is beyond it.
    context "when options were already stripped of the secret keys but the echo remains" do
      let!(:row) do
        task!(
          options: options_for(action: "set_password", username: "u-stripped"),
          error_message: setpw_echo("u-stripped", new_marker),
          events: [ failed_event(setpw_echo("u-stripped", new_marker)) ],
          description: "retry of #{create_echo('u-stripped', marker)}"
        )
      end

      before { run! }

      it "redacts the argv shape in error_message, events and description" do
        expect(row_text(row.id)).not_to include(marker)
        expect(row_text(row.id)).not_to include(new_marker)
        expect(row.reload.error_message)
          .to eq("samba-tool [user setpassword u-stripped --newpassword=[REDACTED]]: exit status 1 (output: ERROR: Failed to set password for user 'u-stripped')")
        expect(row.events.last["message"]).to start_with("samba-tool [user setpassword u-stripped --newpassword=[REDACTED]]: ")
        expect(row.description).to start_with("retry of samba-tool [user create u-stripped [REDACTED]]: ")
      end

      it "does not add option keys the row did not have" do
        expect(row.reload.options).not_to have_key("password")
        expect(row.reload.options).not_to have_key("new_password")
      end

      it "is idempotent on the pattern arm too" do
        expect(run!).to eq(0)
      end
    end

    context "with rows of a shape nothing expected" do
      let!(:scalar_options)  { task!(options: options_for(action: "create", username: "u-s", "password" => marker)) }
      let!(:array_options)   { task!(options: options_for(action: "create", username: "u-a", "password" => marker)) }
      let!(:object_events)   { task!(options: options_for(action: "create", username: "u-e", "password" => marker), error_message: create_echo("u-e", marker)) }
      let!(:odd_elements) do
        task!(
          options: options_for(action: "create", username: "u-m", "password" => marker),
          error_message: create_echo("u-m", marker),
          events: [ "a bare string", 42, nil, { "type" => "failed", "message" => 7 }, { "type" => "failed" }, failed_event(create_echo("u-m", marker)) ]
        )
      end
      let!(:huge) do
        task!(
          options: options_for(action: "create", username: "u-h", "password" => marker),
          error_message: create_echo("u-h", marker, output: "x" * 200_000)
        )
      end

      before do
        set_raw(scalar_options.id, "options = '\"not an object\"'::jsonb")
        set_raw(array_options.id, "options = '[\"password\"]'::jsonb")
        set_raw(object_events.id, "events = '{\"message\": \"not an array\"}'::jsonb")
      end

      # `up` rescues, so "does not raise" alone proves nothing; the abort line
      # must be absent too.
      it "does not abort, scrubs what it can and skips the rest" do
        run!

        expect(@printed).not_to include("scrub aborted")

        expect(scalar_options.reload.options).to eq("not an object")
        expect(array_options.reload.options).to eq([ "password" ])

        expect(object_events.reload.options["password"]).to eq(sentinel)
        expect(object_events.error_message).not_to include(marker)
        expect(object_events.events).to eq("message" => "not an array")

        expect(odd_elements.reload.options["password"]).to eq(sentinel)
        expect(odd_elements.events.first(5)).to eq([ "a bare string", 42, nil, { "type" => "failed", "message" => 7 }, { "type" => "failed" } ])
        expect(odd_elements.events.last["message"]).to start_with("samba-tool [user create u-m [REDACTED]]: ")
        expect(row_text(odd_elements.id)).not_to include(marker)

        expect(huge.reload.error_message).to start_with("samba-tool [user create u-h [REDACTED]]: ")
        expect(huge.error_message.length).to be > 200_000
      end

      it "reports the skipped shapes by count and still terminates when re-run" do
        run!

        expect(@printed).not_to include("scrub aborted")
        expect(@printed).to match(/2 .*options is not a JSON object/)
        expect(@printed).to match(/1 .*events is not a JSON array/)
        expect(@printed).not_to include(marker)
        expect(run!).to eq(0)
        expect(@printed).not_to include("scrub aborted")
      end
    end

    it "is a clean no-op when no row of the command exists" do
      task!(command: "storage.mount", options: { "password" => marker })

      expect(run!).to eq(0)
      expect(@printed).to match(/nothing to scrub/)
      expect(@printed).not_to include("scrub aborted")
      expect(rows_containing(marker)).to eq(1)
    end

    it "sets a bounded lock_timeout for the scrub and restores the session's own afterwards" do
      conn.execute("SET lock_timeout = '12345ms'")

      run!

      expect(@sql.join("\n")).to include("SET lock_timeout = '#{described_class::LOCK_TIMEOUT}'")
      expect(conn.select_value("SHOW lock_timeout")).to eq("12345ms")
    ensure
      conn.execute("SET lock_timeout = 0")
    end

    # Boot safety: a failure inside the scrub must not crash-loop Rails, the
    # thing it prints must not be the exception message (which can carry SQL
    # context and with it row data), and the leftover count must be visible so
    # "stamped but not scrubbed" is readable in the boot log.
    it "does not raise when a batch fails; names the exception class, the leftover count and the rake re-run" do
      task!(options: options_for(action: "create", username: "u-f", "password" => marker))
      allow(migration).to receive(:scrub_batch).and_raise(ActiveRecord::StatementInvalid, "boom with #{marker}")
      allow(Rails.logger).to receive(:error)

      expect { run! }.not_to raise_error

      expect(@printed).to include("scrub aborted by ActiveRecord::StatementInvalid after 0 row(s); 1 candidate row(s) left")
      expect(@printed).to include("re-run with rails system:storage:scrub_smb_task_secrets")
      expect(@printed).not_to include(marker)
      expect(Rails.logger).to have_received(:error).with(a_string_including("ActiveRecord::StatementInvalid").and(satisfy { |s| !s.include?(marker) }))
      expect(conn.select_value("SHOW lock_timeout")).not_to eq(described_class::LOCK_TIMEOUT)
    end

    it "says the leftover count is unknown when even counting fails" do
      allow(migration).to receive(:candidate_count).and_raise(ActiveRecord::StatementInvalid, "boom")

      outcome = migration.suppress_messages { migration.scrub }

      expect(outcome.aborted_by).to eq("ActiveRecord::StatementInvalid")
      expect(outcome.left).to be_nil
      expect(outcome.scrubbed).to eq(0)
    end
  end

  # Row locks held by ANOTHER connection. Transactional fixtures cannot show
  # this (rows inside the example's transaction are invisible to a second
  # connection), so these examples commit their rows and delete them by id.
  describe "rows a concurrent transaction holds" do
    self.use_transactional_tests = false

    let(:other) { ActiveRecord::Base.connection_pool.checkout }

    before { other.begin_db_transaction }

    after do
      other.rollback_db_transaction
      ActiveRecord::Base.connection_pool.checkin(other)
      System::Task.where(id: @ids).delete_all if @ids
      System::Node.where(id: @node_ids).delete_all if @node_ids
      Account.find_by(id: account.id)&.destroy
    end

    def committed_rows(count)
      rows = Array.new(count) do |i|
        task!(options: options_for(action: "create", username: "u-#{i}", "password" => marker),
              error_message: create_echo("u-#{i}", marker))
      end
      @ids = rows.map(&:id)
      @node_ids = rows.map(&:operable_id).uniq
      rows
    end

    it "skips a row another transaction holds FOR UPDATE, reports it, and scrubs it on the next run" do
      rows = committed_rows(3)
      held = rows.last
      other.execute("SELECT id FROM system_tasks WHERE id = #{other.quote(held.id)} FOR UPDATE")

      expect(run!).to eq(2)

      expect(@printed).to match(/scrubbed 2 /)
      expect(@printed).to include("1 candidate row(s) not scrubbed (locked by a concurrent transaction")
      expect(@printed).to include("re-run with rails system:storage:scrub_smb_task_secrets")
      expect(row_text(held.id)).to include(marker)
      rows.first(2).each { |row| expect(row_text(row.id)).not_to include(marker) }

      other.rollback_db_transaction
      other.begin_db_transaction # so the after hook's rollback has one to roll back

      expect(run!).to eq(1)
      expect(row_text(held.id)).not_to include(marker)
    end

    # A table-level lock is the one wait SKIP LOCKED cannot avoid; lock_timeout
    # turns it into the rescued path, leaving the row for the rake re-run.
    it "gives up on a table lock after the lock_timeout instead of hanging, and leaves the row for the re-run" do
      rows = committed_rows(1)
      other.execute("LOCK TABLE system_tasks IN ACCESS EXCLUSIVE MODE")

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect { run! }.not_to raise_error
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(@printed).to include("scrub aborted by ActiveRecord::LockWaitTimeout")
      expect(@printed).to include("leftover candidate count unknown")
      expect(elapsed).to be < 30
      expect(conn.select_value("SHOW lock_timeout")).not_to eq(described_class::LOCK_TIMEOUT)

      other.rollback_db_transaction
      other.begin_db_transaction

      expect(run!).to eq(1)
      expect(row_text(rows.first.id)).not_to include(marker)
    end
  end

  describe "#down" do
    it "is a no-op: the plaintext is gone by design and there is nothing to restore" do
      row = task!(options: options_for(action: "create", username: "u", "password" => marker))
      run!
      snapshot = table_snapshot

      expect { migration.suppress_messages { migration.down } }.not_to raise_error

      expect(table_snapshot).to eq(snapshot)
      expect(row.reload.options["password"]).to eq(sentinel)
    end
  end
end
