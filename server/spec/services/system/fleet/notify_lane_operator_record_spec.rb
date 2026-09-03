# frozen_string_literal: true

require "rails_helper"

# APO-2d (IMP-25949cfd28fd) — the "notify" half of notify_and_proceed, and the
# BaseSkillExecutor audit trail, both terminated in Rails.logger.
#
# WHY IT MATTERS: `notify_and_proceed` is the policy an operator picks when they
# want the fleet to act AND to be told. What they got was one
# `Rails.logger.info` line on the reconciler host — invisible to the approval
# UI, to `system_recent_signals`, to `system_inspect_correlation`, and to every
# compliance read. The ten `*_investigate` notify-only lanes (no applier
# exists; the notification IS the remediation) therefore delivered nothing at
# all. Symmetrically, a skill executor driven directly — an MCP call, a
# reconciler's #invoke_skill, a replayed approval — wrote its start/finish/error
# audit to stdout only, so an operation that ran outside a fleet tick left no
# durable record that it had ever happened. (Ten such lanes, not eleven as the
# finding read: `command grep -rho "system\.[a-z_]*_investigate" app/ | sort -u`
# returns 10.)
#
# The durable record is a System::FleetEvent (persisted + broadcast on
# SystemFleetChannel by System::Fleet::EventBroadcaster). This spec pins the
# EMIT, not a frontend surface — the operator UI for the remediation lane is
# separately approved work (offer 01a053ec).
RSpec.describe "notify lanes and skill executions leave a durable operator record" do
  let(:account) { create(:account) }

  describe System::Fleet::FleetAutonomyService do
    let(:agent)   { create(:ai_agent, account: account, agent_type: "monitor", name: "Fleet Autonomy") }
    let(:service) { described_class.new(account: account, agent: agent) }

    def seed_policy!(category, policy)
      ::Ai::InterventionPolicy.create!(
        account: account, ai_agent_id: agent.id, scope: "agent",
        action_category: category, policy: policy, is_active: true
      )
    end

    it "emits a durable, broadcast FleetEvent for a notify_and_proceed decision" do
      seed_policy!("system.module_verify_investigate", "notify_and_proceed")

      result = service.gate_action!(
        "system.module_verify_investigate",
        metadata: { "instance_id" => nil },
        reasoning: { summary: "module verify failed on 3 nodes" }
      )

      expect(result[:gate]).to eq("notify_and_proceed")

      event = System::FleetEvent.find_by(
        account_id: account.id,
        kind: described_class::NOTIFY_EVENT_KIND
      )
      expect(event).to be_present,
                       "expected notify_and_proceed to leave a durable FleetEvent, not just a log line"
      expect(event.severity).to eq("medium")
      expect(event.source).to eq("fleet_autonomy")
      expect(event.payload["action_category"]).to eq("system.module_verify_investigate")
      expect(event.payload["summary"]).to eq("module verify failed on 3 nodes")
      expect(event.payload["gate"]).to eq("notify_and_proceed")
      expect(event.correlation_id).to be_present
    end

    # The notification is worth little if it cannot be joined to the decision it
    # belongs to: system_inspect_correlation walks by correlation_id, and
    # EventBroadcaster#emit_decision! keys its decision events off the signal
    # fingerprint. A freshly minted id here would file the notification in a
    # chain of its own — a mutation the example above cannot see, because it
    # only asks that SOME correlation_id is present.
    it "correlates the notification with the signal's own decision chain" do
      seed_policy!("system.task_backlog_investigate", "notify_and_proceed")

      service.gate_action!(
        "system.task_backlog_investigate",
        metadata: { "signal_kind" => "system.task_backlog", "signal_fingerprint" => "fp-abc123" },
        reasoning: { summary: "42 tasks stuck" }
      )

      event = System::FleetEvent.find_by(account_id: account.id,
                                         kind: described_class::NOTIFY_EVENT_KIND)
      expect(event.correlation_id).to eq("fp-abc123")
      expect(event.payload["signal_kind"]).to eq("system.task_backlog")
    end

    # Mutation oracle for the emit's PLACEMENT: an unconditional emit inside
    # gate_action! would also fire here, and the example above could not tell.
    it "does not emit the notify event for an auto_approve decision" do
      seed_policy!("system.cert_rotate", "auto_approve")

      service.gate_action!("system.cert_rotate", reasoning: { summary: "rotate" })

      expect(
        System::FleetEvent.where(account_id: account.id, kind: described_class::NOTIFY_EVENT_KIND)
      ).to be_empty
    end

    it "broadcasts the notify event on the account's fleet channel" do
      seed_policy!("system.node_lkg_investigate", "notify_and_proceed")
      expect(ActionCable.server).to receive(:broadcast)
        .with("system_fleet:#{account.id}", hash_including(kind: described_class::NOTIFY_EVENT_KIND))

      service.gate_action!("system.node_lkg_investigate", reasoning: { summary: "lkg stale" })
    end
  end

  describe System::Ai::Skills::BaseSkillExecutor do
    let(:ok_class) do
      Class.new(described_class) do
        skill_descriptor(
          name: "apo2d_ok_skill", description: "for spec", category: "fleet",
          inputs: { node_instance_id: { type: "string", required: true } }, outputs: {}
        )

        protected

        def perform(node_instance_id:)
          success(seen: node_instance_id)
        end
      end
    end

    let(:boom_class) do
      Class.new(described_class) do
        skill_descriptor(
          name: "apo2d_boom_skill", description: "for spec", category: "fleet",
          inputs: {}, outputs: {}
        )

        protected

        def perform
          raise ArgumentError, "detonated"
        end
      end
    end

    def events(kind)
      System::FleetEvent.where(account_id: account.id, kind: kind)
    end

    # Deliberately shaped like the material the redaction exists for. Asserted
    # by CONTAINMENT below, so it survives a rename of the payload key.
    let(:secretish_input) { "i-SECRET-TOKEN-4f2b" }

    it "records the start and the finish of a direct invocation as FleetEvents" do
      result = ok_class.new(account: account).execute(node_instance_id: secretish_input)
      expect(result[:success]).to be(true)

      started  = events(described_class::EVENT_KIND_STARTED).first
      finished = events(described_class::EVENT_KIND_FINISHED).first

      expect(started).to be_present,
                         "expected audit_log_start to leave a durable FleetEvent, not just a log line"
      expect(finished).to be_present,
                          "expected audit_log_finish to leave a durable FleetEvent, not just a log line"

      # Both halves of one invocation must be joinable — system_inspect_correlation
      # walks by correlation_id, and a start you cannot pair with its finish is
      # not an audit trail.
      expect(started.correlation_id).to be_present
      expect(finished.correlation_id).to eq(started.correlation_id)

      expect(started.source).to eq("skill_executor")
      expect(started.payload["skill"]).to eq("apo2d_ok_skill")
      # Input KEYS only — values can carry operator secrets, and the log line
      # this replaces deliberately recorded keys alone.
      expect(started.payload["input_keys"]).to eq([ "node_instance_id" ])

      # CONTAINMENT, not a name check: `not_to have_key("inputs")` forbids one
      # literal key, so a mutant that stores the same values under "args" (or
      # merges them at the top level) walks straight past it. The property is
      # that the VALUE never reaches the row, whatever it is called — and the
      # row is persisted AND broadcast, so this is the privacy oracle for both.
      expect(started.payload.to_json).not_to include(secretish_input)

      expect(finished.payload["success"]).to be(true)
      expect(finished.severity).to eq("low")
    end

    # An executor's inputs are not the only free-form text on the row: a
    # provider's error string and an exception message both land in a jsonb
    # column and go out on the account channel, where they used to be a
    # server-local log line. Unbounded, one provider stack trace is the whole
    # payload budget.
    it "bounds the free-form error text it persists and broadcasts" do
      long = "x" * (described_class::AUDIT_TEXT_LIMIT + 500)
      klass = Class.new(described_class) do
        skill_descriptor(name: "apo2d_long_error", description: "for spec", category: "fleet",
                         inputs: {}, outputs: {})

        protected

        define_method(:perform) { raise ArgumentError, long }
      end

      klass.new(account: account).execute

      failed = events(described_class::EVENT_KIND_FAILED).first
      expect(failed.payload["error"].length).to be <= described_class::AUDIT_TEXT_LIMIT
      # The class still identifies the failure exactly; only the message is cut.
      expect(failed.payload["error_class"]).to eq("ArgumentError")
    end

    # IMP-675ed7763230. Input VALUES never reach the payload (keys only, above),
    # but the failure path copied exc.message verbatim, and a provider SDK or
    # HTTP client routinely embeds the credential in the message it raises:
    # the clone URL with its userinfo, the request URL with its query-string
    # token, the header it sent. Bounding the text to AUDIT_TEXT_LIMIT is not
    # a redaction, so the material the input redaction kept out came straight
    # back in through the error string — persisted to system_fleet_events and
    # broadcast on the account channel. Asserted by CONTAINMENT on the secret
    # bytes so the assertion survives any change to the redaction marker.
    describe "secret shapes in free-form error text" do
      let(:userinfo_secret) { "ghp_9f8e7d6c5b4a3928170605abcdefabcdefab" }
      let(:query_secret)    { "qs-4d2c1b0a9f8e7d6c5b4a3928170605" }
      let(:bearer_secret)   { "brr-a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6" }
      let(:leaky_message) do
        "GET https://ci:#{userinfo_secret}@git.example.test/repo.git?access_token=#{query_secret} " \
          "with Authorization: Bearer #{bearer_secret} failed: 401"
      end

      def raising_class(message)
        Class.new(described_class) do
          skill_descriptor(name: "imp675_leaky_error", description: "for spec", category: "fleet",
                           inputs: {}, outputs: {})

          protected

          define_method(:perform) { raise ArgumentError, message }
        end
      end

      it "scrubs credential shapes out of a raised exception's message before persisting it" do
        raising_class(leaky_message).new(account: account).execute

        failed = events(described_class::EVENT_KIND_FAILED).first
        expect(failed).to be_present
        persisted = failed.payload["error"]
        expect(persisted).not_to include(userinfo_secret)
        expect(persisted).not_to include(query_secret)
        expect(persisted).not_to include(bearer_secret)
        # Still diagnosable: the scheme, host and the HTTP status survive.
        expect(persisted).to include("https://ci:")
        expect(persisted).to include("git.example.test")
        expect(persisted).to include("401")
        expect(failed.payload["error_class"]).to eq("ArgumentError")
      end

      it "scrubs the broadcast copy as well as the persisted one" do
        broadcast = nil
        allow(ActionCable.server).to receive(:broadcast) do |channel, payload|
          broadcast = payload if channel == "system_fleet:#{account.id}" &&
                                 payload[:kind] == described_class::EVENT_KIND_FAILED
        end

        raising_class(leaky_message).new(account: account).execute

        expect(broadcast).to be_present
        wire = broadcast.to_json
        expect(wire).not_to include(userinfo_secret)
        expect(wire).not_to include(query_secret)
        expect(wire).not_to include(bearer_secret)
      end

      it "scrubs a failure RESULT's error string on the finish event too" do
        message = leaky_message
        klass = Class.new(described_class) do
          skill_descriptor(name: "imp675_leaky_result", description: "for spec", category: "fleet",
                           inputs: {}, outputs: {})

          protected

          define_method(:perform) { failure(message) }
        end

        klass.new(account: account).execute

        finished = events(described_class::EVENT_KIND_FINISHED).first
        expect(finished.payload["success"]).to be(false)
        expect(finished.payload["error"]).not_to include(userinfo_secret)
        expect(finished.payload["error"]).not_to include(query_secret)
        expect(finished.payload["error"]).not_to include(bearer_secret)
      end

      # ORDER oracle: redact, THEN bound. A secret that straddles the
      # AUDIT_TEXT_LIMIT cut would leave its leading bytes behind if the text
      # were truncated first and only then scrubbed. The shape is deliberately
      # FIXED-WIDTH (an AWS access key id: AKIA + 16 chars, word-bounded): a
      # `token=...` shape would not discriminate, because the sanitizer's
      # key=value pattern still matches the clipped 11-char tail and a
      # truncate-first mutant would pass. A clipped AKIA fragment matches
      # nothing, so it leaks under the wrong order and only the wrong order.
      it "redacts before it truncates, so a secret straddling the cut leaves no fragment" do
        secret  = "AKIAABCDEFGHIJKLMNOP"
        # 484 + " " + 20 = 505: String#truncate keeps 497 chars + "...", so a
        # truncate-first pass would keep "AKIAABCDEFGH" (12 chars) verbatim.
        message = ("x" * (described_class::AUDIT_TEXT_LIMIT - 16)) + " #{secret}"

        raising_class(message).new(account: account).execute

        persisted = events(described_class::EVENT_KIND_FAILED).first.payload["error"]
        expect(persisted.length).to be <= described_class::AUDIT_TEXT_LIMIT
        expect(persisted).not_to include(secret[0, 12])
      end

      # SLICE oracle, the order oracle's twin one layer up. #audit_text only
      # runs the patterns over the first 4x AUDIT_TEXT_LIMIT chars so a
      # megabyte provider error does not cost a full scan. The trap is that
      # redaction SHRINKS text far more than it grows it — a PEM block
      # collapses to "[REDACTED]" — so bytes that started PAST the slice can
      # land inside the persisted 500-char window even though the slice cut
      # them before any pattern ran. A fixed-width secret straddling that cut
      # is then persisted as an unmatched fragment. The fixture puts a PEM
      # (which collapses ~1.5KB to 10 chars) ahead of an AKIA token positioned
      # so exactly 9 of its 20 chars fall on the near side of the slice.
      it "leaves no fragment of a secret straddling the redaction-input slice" do
        limit  = described_class::AUDIT_TEXT_LIMIT
        slice  = limit * 4
        secret = "AKIAZZZZZZZZZZZZZZZZ"
        pem_body = (["MIIEowIBAAKCAQEAxGqQnMHYQm0lWJ9d3cVfLpQ8ZzYqR1sTnUvWxYz0AbCdEfGh"] * 23).join("\n")
        pem = "-----BEGIN RSA PRIVATE KEY-----\n#{pem_body}\n-----END RSA PRIVATE KEY-----"
        filler = slice - pem.length - 10
        # Fixture preconditions: the secret really does straddle the slice, and
        # what survives redaction really does fit under the limit (otherwise
        # the truncate, not the fix, would be what hides the fragment).
        expect(filler).to be_positive
        expect(filler + secret.length).to be < limit
        message = pem + ("y" * filler) + " #{secret}"
        expect(message.length).to be > slice

        raising_class(message).new(account: account).execute

        persisted = events(described_class::EVENT_KIND_FAILED).first.payload["error"]
        expect(persisted.length).to be < limit, "fixture must not be saved by the truncate"
        expect(persisted).not_to include(secret[0, 9])
      end

      # The scrubber's patterns raise ArgumentError on invalid UTF-8, and
      # #audit_log_error runs INSIDE #execute's rescue — a raise there would
      # escape #execute with the audit half-written. Provider errors are not
      # text the platform authored, so the bytes must be scrubbed first.
      it "survives an exception message that is not valid UTF-8" do
        message = "provider said \xFF\xFE no token=abcdefghijklmnop".dup.force_encoding("UTF-8")
        expect(message.valid_encoding?).to be(false)

        result = nil
        expect { result = raising_class(message).new(account: account).execute }.not_to raise_error
        expect(result[:success]).to be(false)

        failed = events(described_class::EVENT_KIND_FAILED).first
        expect(failed).to be_present, "expected the failure to still leave a durable FleetEvent"
        expect(failed.payload["error"]).not_to include("abcdefghijklmnop")
      end

      # The BINARY twin of the case above, and the one String#scrub alone does
      # not close: every byte is "valid" in ASCII-8BIT, so .scrub is a no-op
      # and the bytes sail through to the jsonb persist, which rejects them —
      # and #emit_audit_event! swallows that, dropping the durable row for
      # precisely the least-trusted failures. Only a force_encoding to UTF-8
      # ahead of the scrub gives those bytes to the scrubber at all.
      it "survives an exception message carrying binary (ASCII-8BIT) bytes" do
        message = "provider said \xC3\x28 no token=abcdefghijklmnop".dup.force_encoding("ASCII-8BIT")
        expect(message.valid_encoding?).to be(true), "fixture must be VALID as binary, else it proves nothing"

        result = nil
        expect { result = raising_class(message).new(account: account).execute }.not_to raise_error
        expect(result[:success]).to be(false)

        failed = events(described_class::EVENT_KIND_FAILED).first
        expect(failed).to be_present, "expected the binary failure to still leave a durable FleetEvent"
        expect(failed.payload["error"]).not_to include("abcdefghijklmnop")
      end

      # The slice guard's OWN failure mode, and the one that costs the operator
      # the whole record rather than a fragment of one. Dropping the token the
      # slice cut in half is `sub(/\S+\z/, "")`, which removes the trailing RUN
      # — and a machine-generated body (minified JSON, a base64 blob, a stack
      # frame path) can be one unbroken run for the entire slice. Strip that
      # and the persisted `error` is the empty string: the durable operator
      # record this whole lane exists to create, gone, for exactly the class of
      # provider error most likely to be long.
      it "still persists a diagnosable reason when the slice holds no whitespace at all" do
        slice = described_class::AUDIT_TEXT_LIMIT * 4
        # No space anywhere in the first `slice` characters, and longer than
        # the slice, so the cut fires and the trailing run IS the whole slice.
        message = 'Faraday::TooManyRequestsError:{"errors":[{"status":"429",' \
                  '"code":"rate_limit_exceeded","resource":"provider-alpha","detail":"' +
                  ("abcdefghijklmnopqrstuvwxyz" * 100) + '"}]}'
        expect(message.length).to be > slice
        expect(message[0, slice]).not_to include(" ")

        raising_class(message).new(account: account).execute

        persisted = events(described_class::EVENT_KIND_FAILED).first.payload["error"]
        expect(persisted).to be_present, "a whitespace-free provider body must still leave a reason"
        expect(persisted).to include("rate_limit_exceeded")
      end
    end

    # A skill dispatched from a fleet tick belongs in the tick's correlation
    # walk. Without this seam the audit rows are unreachable from
    # system_inspect_correlation on the decision that ordered them, which is the
    # same defect #notify_action's fingerprint keying fixes on the other side.
    it "files its audit in the CALLER's correlation chain when it has one" do
      exec = ok_class.new(account: account)
      exec.caller_correlation_id = "fp-tick-99"
      exec.execute(node_instance_id: "i-1")

      expect(events(described_class::EVENT_KIND_STARTED).first.correlation_id).to eq("fp-tick-99")
      expect(events(described_class::EVENT_KIND_FINISHED).first.correlation_id).to eq("fp-tick-99")
    end

    # One chain per CALL, not per object: a memoized id would merge two runs of
    # the same executor instance into a single, unreadable audit chain.
    it "opens a new chain for each execution of the same executor object" do
      exec = ok_class.new(account: account)
      exec.execute(node_instance_id: "i-1")
      exec.execute(node_instance_id: "i-2")

      chains = events(described_class::EVENT_KIND_STARTED).pluck(:correlation_id)
      expect(chains.length).to eq(2)
      expect(chains.uniq.length).to eq(2)
    end

    it "records a raised failure as a high-severity FleetEvent naming the exception" do
      result = boom_class.new(account: account).execute
      expect(result[:success]).to be(false)

      failed = events(described_class::EVENT_KIND_FAILED).first
      expect(failed).to be_present,
                        "expected audit_log_error to leave a durable FleetEvent, not just a log line"
      expect(failed.severity).to eq("high")
      expect(failed.payload["error_class"]).to eq("ArgumentError")
      expect(failed.payload["error"]).to eq("detonated")
      expect(events(described_class::EVENT_KIND_FINISHED)).to be_empty
    end

    # Mutation oracle for the SEVERITY split: a finish that reports a failure
    # result is not the same operator signal as a successful one.
    it "raises the finish severity when perform returns a failure result" do
      klass = Class.new(described_class) do
        skill_descriptor(name: "apo2d_soft_fail", description: "for spec", category: "fleet",
                         inputs: {}, outputs: {})

        protected

        def perform
          failure("provider said no")
        end
      end

      klass.new(account: account).execute

      finished = events(described_class::EVENT_KIND_FINISHED).first
      expect(finished).to be_present
      expect(finished.payload["success"]).to be(false)
      expect(finished.severity).to eq("medium")
    end

    # The audit trail is observability: it must never be the reason a fleet
    # operation fails. EventBroadcaster swallows its own errors; this pins that
    # the executor does not reintroduce a raise around it.
    it "still returns the perform result when the event write fails" do
      allow(System::Fleet::EventBroadcaster).to receive(:emit!)
        .and_raise(ActiveRecord::StatementInvalid, "events table gone")

      result = ok_class.new(account: account).execute(node_instance_id: "i-1")

      expect(result[:success]).to be(true)
      expect(result.dig(:data, :seen)).to eq("i-1")
    end
  end
end
