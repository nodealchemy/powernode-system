# frozen_string_literal: true

require "rails_helper"

# IMP-54c73634c1d7 — system_get_task include_events. The agent computes a
# scrubbed log_tail for a module build and it rides on the task's events
# (System::Task has no result column), but the tool never serialized events,
# so a build log was stored and invisible. include_events: true returns them,
# every string passed through the same redactor error_message uses.
RSpec.describe Ai::Tools::SystemFleetTool, "system_get_task include_events" do
  include ActiveSupport::Testing::TimeHelpers

  let(:account)  { create(:account) }
  let(:platform_record) { create(:system_node_platform, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform_record) }
  let(:node) { create(:system_node, account: account, node_template: template, name: "evtnode") }
  let(:tool) { described_class.new(account: account, internal: true) }

  # Obviously fake values, shaped like what the redactor targets.
  let(:fake_bearer)  { "Bearer FAKEFAKEFAKEFAKEFAKEFAKEFAKE0001" }
  let(:fake_password) { "password=FAKEhunter2FAKE" }
  let(:fake_pem) do
    "-----BEGIN PRIVATE KEY-----\nFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE\n-----END PRIVATE KEY-----"
  end

  # travel truncates sub-second precision; start on a whole second so the
  # wait deadline arithmetic advances under the stubbed sleep.
  before { travel_to(Time.current.change(usec: 0)) }
  after { travel_back }

  def call(**rest)
    tool.execute(params: { action: "system_get_task" }.merge(rest))
  end

  def build_task(events:, status: "complete", account: self.account)
    System::Task.create!(account: account, command: "ci.module_build", status: status,
                         operable_type: "System::Node", operable_id: node.id, events: events)
  end

  def completed_event(result, message: "Completed by instance")
    { "type" => "completed", "message" => message, "result" => result, "timestamp" => Time.current.iso8601 }
  end

  let(:log_tail) { "step 1 ok\nstep 2 ok\nbuild finished" }
  let!(:task) { build_task(events: [ completed_event({ "oci_digest" => "sha256:abc", "log_tail" => log_tail }) ]) }

  it "keeps the reply unchanged, with no event keys, when include_events is absent or false" do
    [ {}, { include_events: false }, { include_events: "false" } ].each do |extra|
      r = call(task_id: task.id, **extra)
      expect(r[:success]).to be true
      expect(r[:data].keys).to eq([ :task ])
      expect(r[:data][:task].keys).to eq(%i[id command status progress operable_type operable_id error_message created_at completed_at])
    end
  end

  it "returns the events with result.log_tail when include_events is true" do
    [ true, "true" ].each do |flag|
      r = call(task_id: task.id, include_events: flag)

      expect(r[:success]).to be true
      expect(r[:data][:task][:id]).to eq(task.id)
      expect(r[:data][:events_total]).to eq(1)
      expect(r[:data][:events_truncated]).to be false
      event = r[:data][:events].first
      expect(event["type"]).to eq("completed")
      expect(event["result"]["log_tail"]).to eq(log_tail)
      expect(event["result"]["oci_digest"]).to eq("sha256:abc")
    end
  end

  it "returns an empty list for a task with no events" do
    bare = build_task(events: [])
    r = call(task_id: bare.id, include_events: true)

    expect(r[:data][:events]).to eq([])
    expect(r[:data][:events_total]).to eq(0)
    expect(r[:data][:events_truncated]).to be false
  end

  describe "redaction" do
    it "redacts credentials planted in log_tail" do
      planted = "clone failed\nAuthorization: #{fake_bearer}\n#{fake_password}\n#{fake_pem}\ndone"
      t = build_task(events: [ completed_event({ "log_tail" => planted }) ])

      r = call(task_id: t.id, include_events: true)
      tail = r[:data][:events].first["result"]["log_tail"]

      expect(tail).not_to include("FAKEFAKEFAKEFAKEFAKEFAKEFAKE0001")
      expect(tail).not_to include("FAKEhunter2FAKE")
      expect(tail).not_to include("BEGIN PRIVATE KEY")
      expect(tail).not_to include("FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE")
      expect(tail).to include("clone failed").and include("[REDACTED]").and include("done")
    end

    it "redacts credentials elsewhere in an event: message, data, nested and array values" do
      t = build_task(events: [ {
        "type" => "failed",
        "message" => "push failed #{fake_password}",
        "data" => { "argv" => [ "login", "--password", "FAKEargvSECRET99" ], "nested" => { "note" => fake_bearer } },
        "result" => { "steps" => [ { "out" => fake_pem } ] }
      } ])

      r = call(task_id: t.id, include_events: true)
      body = JSON.generate(r[:data][:events])

      %w[FAKEhunter2FAKE FAKEargvSECRET99 FAKEFAKEFAKEFAKEFAKEFAKEFAKE0001 FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE].each do |secret|
        expect(body).not_to include(secret)
      end
      expect(r[:data][:events].first["type"]).to eq("failed")
    end

    it "redacts a bare secret value held under a credential-named key" do
      t = build_task(events: [ completed_event({ "api_key" => "FAKEkeyvalue123456", "sha" => "sha256:abc" }) ])

      r = call(task_id: t.id, include_events: true)
      result = r[:data][:events].first["result"]

      expect(JSON.generate(result)).not_to include("FAKEkeyvalue123456")
      expect(result["sha"]).to eq("sha256:abc")
    end

    # A secret whose VALUE straddles the cut. The events cut is `cap` minus the
    # marker, so that is the offset the value must cross: if the cut came before
    # the redaction, the four value characters inside the window would be served
    # raw (a 4-character fragment is too short for the redactor to see on its own).
    it "redacts before cutting a head-bounded string: a secret straddling the cut is gone" do
      cap = described_class::GET_ERROR_MESSAGE_LIMIT
      window = cap - "...[truncated]".length
      # " password=" is 10 characters, so the value starts 4 characters inside the window.
      text = ("x" * (window - 14)) + " password=FAKEhunter2FAKE" + (" tail" * 10)
      t = build_task(events: [ completed_event({ "detail" => text }) ])

      detail = call(task_id: t.id, include_events: true)[:data][:events].first["result"]["detail"]

      expect(detail.length).to be <= cap
      expect(detail).to end_with("...[truncated]")
      expect(detail).not_to include("FAKE")
      expect(detail).not_to include("hunter")
    end

    it "redacts before cutting a tail-bounded log_tail: a secret straddling the cut is gone, the end is kept" do
      cap = described_class::GET_ERROR_MESSAGE_LIMIT
      window = cap - "[truncated]...".length
      # The last `window` characters begin 6 characters before the value ends.
      text = ("x" * 20_000) + " password=FAKEhunter2FAKE" + " " + ("y" * (window - 7))
      t = build_task(events: [ completed_event({ "log_tail" => text }) ])

      tail = call(task_id: t.id, include_events: true)[:data][:events].first["result"]["log_tail"]

      expect(tail.length).to be <= cap
      expect(tail).to start_with("[truncated]...")
      expect(tail).to end_with("y" * 50)
      expect(tail).not_to include("FAKE")
      expect(tail).not_to include("hunter")
    end

    it "redacts a secret planted in a hash KEY" do
      key = "Bearer FAKEFAKEFAKEFAKEFAKEFAKEFAKE0001"
      t = build_task(events: [ completed_event({ key => "value" }) ])

      result = call(task_id: t.id, include_events: true)[:data][:events].first["result"]

      expect(JSON.generate(result)).not_to include("FAKEFAKEFAKE")
      expect(result.keys).to eq([ "Bearer [REDACTED]" ])
    end

    it "keeps two keys that redact to the same text apart, deterministically" do
      k1 = "Bearer FAKEFAKEFAKEFAKEFAKEFAKEFAKE0001"
      k2 = "Bearer FAKEFAKEFAKEFAKEFAKEFAKEFAKE0002"
      t = build_task(events: [ completed_event({ k1 => "one", k2 => "two" }) ])

      result = call(task_id: t.id, include_events: true)[:data][:events].first["result"]

      expect(result.keys).to eq([ "Bearer [REDACTED]", "Bearer [REDACTED]#2" ])
    end

    # The lead (the key, here) is stripped back off after redaction. A redaction
    # that rewrote the lead itself means the value cannot be located: withhold it.
    it "withholds a value whole when redaction altered the lead it was read with" do
      t = build_task(events: [ completed_event({ "-----BEGIN PRIVATE KEY-----" => "innocuous value" }) ])

      result = call(task_id: t.id, include_events: true)[:data][:events].first["result"]

      expect(result).to eq({ "[REDACTED]" => "[REDACTED]" })
    end

    describe "arrays of strings are redacted as a whole" do
      def result_of(value)
        t = build_task(events: [ completed_event({ "argv" => value }) ])
        call(task_id: t.id, include_events: true)[:data][:events].first["result"]["argv"]
      end

      it "withholds an oras login argv whose -p sits two elements after login" do
        out = result_of(%w[oras login -u ci -p FAKEsecret123])

        expect(JSON.generate(out)).not_to include("FAKEsecret123")
      end

      it "withholds a PEM split across array lines, including the lines after the second" do
        pem = [ "-----BEGIN PRIVATE KEY-----", "FAKEFAKEFAKEFAKEFAKEFAKEFAKE0001",
                "FAKEFAKEFAKEFAKEFAKEFAKEFAKE0002", "FAKEFAKEFAKEFAKEFAKEFAKEFAKE0003",
                "-----END PRIVATE KEY-----" ]
        out = result_of(pem)

        expect(JSON.generate(out)).not_to include("FAKEFAKEFAKE")
      end

      it "withholds a .netrc line split across elements" do
        out = result_of(%w[machine registry.example.test login ci password FAKEnetrcSECRET99])

        expect(JSON.generate(out)).not_to include("FAKEnetrcSECRET99")
      end

      it "withholds a curl -u user:token split across elements" do
        out = result_of(%w[curl -u ci:FAKEcurlTOKEN99 https://example.test])

        expect(JSON.generate(out)).not_to include("FAKEcurlTOKEN99")
      end

      it "withholds an argv broken by a non-string element" do
        out = result_of([ "oras", "login", "-u", "ci", true, "-p", "FAKEsecret123" ])

        expect(JSON.generate(out)).not_to include("FAKEsecret123")
        expect(out).to include(true)
      end

      it "withholds an argv split across nested arrays, nested strings included" do
        out = result_of([ %w[docker login], %w[-p FAKEsecretX9] ])

        expect(out).to eq([ [ "[REDACTED]", "[REDACTED]" ], [ "[REDACTED]", "[REDACTED]" ] ])
      end

      it "keeps the retained lines of a tail-bounded array from starting inside a PEM whose BEGIN line was dropped" do
        body = %w[FAKEFAKEFAKEFAKEFAKEFAKEFAKE0001 FAKEFAKEFAKEFAKEFAKEFAKEFAKE0002 FAKEFAKEFAKEFAKEFAKEFAKEFAKE0003]
        lines = [ "-----BEGIN PRIVATE KEY-----" ] + body + Array.new(47) { |i| "build line #{i}" }
        t = build_task(events: [ completed_event({ "stderr" => lines }) ])

        out = call(task_id: t.id, include_events: true)[:data][:events].first["result"]["stderr"]

        expect(JSON.generate(out)).not_to include("FAKEFAKEFAKE")
        expect(out.last).to eq("build line 46")
      end

      # The check and the output must see the SAME slice at every nesting level:
      # this nested log array is longer than 50, so what is emitted (the last 50)
      # includes items the first 50 never contained.
      it "checks exactly the retained slice of a nested log array" do
        nested = Array.new(50) { "x" } + %w[oras login -p FAKEsecret1]
        t = build_task(events: [ completed_event({ "stderr" => [ nested ] }) ])

        out = call(task_id: t.id, include_events: true)[:data][:events].first["result"]["stderr"]

        expect(JSON.generate(out)).not_to include("FAKEsecret1")
      end

      it "withholds an array too large to check, without checking it" do
        big = Array.new(20) { "q" * 20_000 }
        out = result_of(big)

        expect(out).to all(eq("[REDACTED]"))
      end

      it "leaves an array of ordinary strings intact" do
        expect(result_of([ "make", "-j4", "all" ])).to eq([ "make", "-j4", "all" ])
      end
    end

    describe "a secret-named key withholds its whole subtree" do
      def result_of(hash)
        t = build_task(events: [ completed_event(hash) ])
        call(task_id: t.id, include_events: true)[:data][:events].first["result"]
      end

      [
        [ "password", "short" ],
        [ "password", "correct horse battery staple" ],
        [ "password", { "value" => "FAKEnested" } ],
        [ "password", 12_345_678 ],
        [ "pwd", "x" ],
        [ "pass", "y" ],
        [ "DB_PASS", "abc" ],
        [ "passphrase", [ "a", "b" ] ],
        [ "apiKey", "k" ],
        [ "client_secret", { "a" => [ "b" ] } ],
        [ "access_key", "z" ],
        [ "private_key", "z" ],
        [ "credentials", { "user" => "u" } ],
        [ "Authorization", "abc" ],
        [ "auth", "abc" ],
        [ "cookie", "abc" ],
        [ "session", "abc" ],
        [ "signature", "abc" ],
        [ "x-auth-token", "abc" ],
        [ "pin", 123_456 ],
        [ "otp", "1" ],
        [ "passcode", "x" ],
        [ "totp", 123_456 ],
        [ "mfa", "x" ],
        [ "master_key", "short" ],
        [ "signing_key", 1 ],
        [ "encryptionKey", "x" ],
        [ "ssh_keys", [ "a" ] ],
        [ "key", "short" ]
      ].each do |key, value|
        it "withholds #{value.class} under #{key.inspect}" do
          expect(result_of({ key => value, "sha" => "sha256:abc" })).to eq({ key => "[REDACTED]", "sha" => "sha256:abc" })
        end
      end

      it "withholds every descendant of a secret-named ancestor, whatever its own key" do
        out = result_of({ "credentials" => { "user" => { "name" => "n" }, "list" => [ 1, 2 ] } })

        expect(out).to eq({ "credentials" => "[REDACTED]" })
      end

      it "does not withhold obvious non-secrets" do
        safe = { "token_count" => 3, "passed" => true, "bypass" => "ok", "author" => "me", "compass" => "n",
                 "sort_key" => "a", "cache_key" => "b", "primary_key" => "id", "foreign_key" => "fk",
                 "idempotency_key" => "c", "partition_key" => "d", "public_key" => "pk1" }

        expect(result_of(safe)).to eq(safe)
      end

      it "leaves a nil value under a secret-named key as nil" do
        expect(result_of({ "password" => nil })).to eq({ "password" => nil })
      end
    end

    # jsonb cannot hold invalid UTF-8, so this is defence in depth: the
    # redaction regexes raise ArgumentError on it, and the serializer scrubs.
    it "does not raise on invalid UTF-8 in captured output" do
      bad = "ok \xFF\xFE #{fake_password}".dup.force_encoding("UTF-8")
      allow_any_instance_of(System::Task).to receive(:events).and_return([ completed_event({ "log_tail" => bad }) ]) # rubocop:disable RSpec/AnyInstance

      r = call(task_id: task.id, include_events: true)

      expect(r[:success]).to be(true), r[:error].to_s
      expect(r[:data][:events].first["result"]["log_tail"]).not_to include("FAKEhunter2FAKE")
    end
  end

  describe "bounding" do
    let!(:many) do
      build_task(events: Array.new(35) { |i| { "type" => "progress", "message" => "step #{i}", "timestamp" => Time.current.iso8601 } })
    end

    it "returns the newest events only, oldest first, with the total and a truncated flag" do
      r = call(task_id: many.id, include_events: true)
      cap = described_class::TASK_EVENTS_LIMIT

      expect(r[:data][:events].size).to eq(cap)
      expect(r[:data][:events_total]).to eq(35)
      expect(r[:data][:events_truncated]).to be true
      expect(r[:data][:events].last["message"]).to eq("step 34")
      expect(r[:data][:events].first["message"]).to eq("step #{35 - cap}")
    end

    it "does not flag truncation at exactly the cap" do
      cap = described_class::TASK_EVENTS_LIMIT
      exact = build_task(events: Array.new(cap) { |i| { "type" => "progress", "message" => "s#{i}" } })

      r = call(task_id: exact.id, include_events: true)

      expect(r[:data][:events].size).to eq(cap)
      expect(r[:data][:events_truncated]).to be false
    end

    it "caps each string at the single-task error limit, the marker included" do
      cap = described_class::GET_ERROR_MESSAGE_LIMIT
      t = build_task(events: [ completed_event({ "detail" => "y" * (cap * 3), "log_tail" => "y" * (cap * 3) }) ])

      result = call(task_id: t.id, include_events: true)[:data][:events].first["result"]

      expect(result["detail"]).to eq("#{'y' * (cap - 14)}...[truncated]")
      expect(result["log_tail"]).to eq("[truncated]...#{'y' * (cap - 14)}")
    end

    it "keeps the END of a log_tail, where a long stderr's failure is" do
      text = "stdout: ok\nstderr: #{"noise line\n" * 10_000}FATAL: build exploded\n"
      t = build_task(events: [ completed_event({ "log_tail" => text }) ])

      tail = call(task_id: t.id, include_events: true)[:data][:events].first["result"]["log_tail"]

      expect(tail).to start_with("[truncated]...")
      expect(tail).to end_with("FATAL: build exploded\n")
      expect(tail).not_to include("stdout: ok")
    end

    it "keeps the END of stdout- and stderr-named keys too, and the head of others" do
      text = "HEAD-MARK\n#{"n\n" * 20_000}END-MARK"
      t = build_task(events: [ completed_event({ "stderr" => text, "stdout" => text, "note" => text }) ])

      result = call(task_id: t.id, include_events: true)[:data][:events].first["result"]

      expect(result["stderr"]).to end_with("END-MARK")
      expect(result["stdout"]).to end_with("END-MARK")
      expect(result["note"]).to start_with("HEAD-MARK")
    end

    it "caps a hash key at 200 characters, the marker included" do
      t = build_task(events: [ completed_event({ ("k" * 1000) => "v" }) ])

      result = call(task_id: t.id, include_events: true)[:data][:events].first["result"]

      expect(result.keys.first.length).to be <= 200
    end

    it "spends the string budget newest-first and collapses the older events into ONE marker" do
      cap = described_class::GET_ERROR_MESSAGE_LIMIT
      fat = build_task(events: Array.new(described_class::TASK_EVENTS_LIMIT) { |i| completed_event({ "log_tail" => "z" * cap, "n" => i }) })

      events = call(task_id: fat.id, include_events: true)[:data][:events]
      marker, *kept = events

      expect(marker).to be_a(String)
      expect(marker).to match(/older events.*budget exhausted/)
      expect(kept.size).to be < described_class::TASK_EVENTS_LIMIT - 1
      expect(kept.last["result"]["log_tail"]).to eq("z" * cap)
      expect(kept.map { |e| e["result"]["log_tail"].length }.sum).to be <= described_class::TASK_EVENTS_MAX_CHARS
    end

    it "collapses the rest of a subtree into ONE marker once the budget is gone" do
      cap = described_class::GET_ERROR_MESSAGE_LIMIT
      wide = (0...50).to_h { |i| [ "k#{i}", "v" * cap ] }
      t = build_task(events: [ completed_event(wide) ])

      result = call(task_id: t.id, include_events: true)[:data][:events].first["result"]

      omitted = result.select { |k, _| k.include?("omitted") }
      expect(omitted.size).to eq(1)
      expect(result.size).to be < 15
    end

    # nil values are free, so the only spend here is the keys.
    it "charges hash keys to the budget" do
      keys = (0...50).to_h { |i| [ "k#{i}-#{'q' * 190}"[0, 190], nil ] }
      t = build_task(events: Array.new(20) { completed_event(keys) })

      events = call(task_id: t.id, include_events: true)[:data][:events]

      expect(events.first).to match(/older events.*budget exhausted/)
      expect(events.size).to be < 20
    end

    # Short keys, no strings: the only spend is the numbers' digits.
    it "charges non-string scalars to the budget" do
      numbers = (0...50).to_h { |i| [ "n#{i}", 10**300 ] }
      t = build_task(events: Array.new(20) { completed_event(numbers) })

      events = call(task_id: t.id, include_events: true)[:data][:events]

      expect(events.first).to match(/older events.*budget exhausted/)
      expect(events.size).to be < 20
    end

    it "caps the nodes returned in one reply and says so" do
      row = (0...10).to_h { |i| [ "f#{i}", i ] }
      event = completed_event({ "rows" => Array.new(45) { row } })
      t = build_task(events: Array.new(20) { event })

      events = call(task_id: t.id, include_events: true)[:data][:events]

      count = lambda do |v|
        case v
        when Hash then v.sum { |_, x| 1 + count.call(x) }
        when Array then v.sum { |x| 1 + count.call(x) }
        else 0
        end
      end
      expect(count.call(events)).to be <= 5_000 + 100
      expect(JSON.generate(events)).to match(/omitted/)
    end

    it "bounds nesting depth and collection width" do
      deep = { "a" => { "b" => { "c" => { "d" => { "e" => { "f" => { "g" => "deep-leaf" } } } } } } }
      wide = { "list" => Array.new(500) { |i| "item#{i}" } }
      t = build_task(events: [ completed_event(deep.merge(wide)) ])

      r = call(task_id: t.id, include_events: true)
      body = JSON.generate(r[:data][:events])

      expect(body).not_to include("deep-leaf")
      expect(body).not_to include("item499")
      expect(body).to include("item0")
    end
  end

  it "scopes by account: another account's task is not found, events or not" do
    other_account = create(:account)
    other_platform = create(:system_node_platform, account: other_account)
    other_template = create(:system_node_template, account: other_account, node_platform: other_platform)
    other_node = create(:system_node, account: other_account, node_template: other_template, name: "othernode")
    foreign = System::Task.create!(account: other_account, command: "ci.module_build", status: "complete",
                                   operable_type: "System::Node", operable_id: other_node.id,
                                   events: [ completed_event({ "log_tail" => "foreign log" }) ])

    r = call(task_id: foreign.id, include_events: true)

    expect(r[:success]).to be false
    expect(JSON.generate(r)).not_to include("foreign log")
  end

  describe "composed with wait_seconds" do
    let!(:running) do
      build_task(status: "running", events: [ { "type" => "progress", "message" => "building" } ])
    end

    it "includes the events of the FINAL snapshot, taken after the task finished mid-wait" do
      allow(tool).to receive(:sleep) do
        running.update!(status: "complete",
                        events: running.events + [ completed_event({ "log_tail" => "final tail #{fake_password}" }) ])
      end

      r = call(task_id: running.id, wait_seconds: 30, include_events: true)

      expect(r[:success]).to be true
      expect(r[:data][:timed_out]).to be false
      expect(r[:data][:task][:status]).to eq("complete")
      expect(r[:data][:events_total]).to eq(2)
      tail = r[:data][:events].last["result"]["log_tail"]
      expect(tail).to include("final tail")
      expect(tail).not_to include("FAKEhunter2FAKE")
    end

    it "includes the current events on a timed-out wait" do
      allow(tool).to receive(:sleep) { |s| travel(s.seconds) }

      r = call(task_id: running.id, wait_seconds: 4, include_events: true)

      expect(r[:data][:timed_out]).to be true
      expect(r[:data][:events].first["message"]).to eq("building")
    end
  end

  describe "a non-boolean include_events" do
    it "is refused by name, never read as true or false" do
      [ "banana", 2, [ true ], { "a" => 1 } ].each do |bad|
        r = call(task_id: task.id, include_events: bad)

        expect(r[:success]).to be(false), "include_events: #{bad.inspect}"
        expect(r[:error]).to match(/include_events must be true or false/)
      end
    end

    it "treats nil and an empty string as absent" do
      [ nil, "" ].each do |v|
        r = call(task_id: task.id, include_events: v)
        expect(r[:data].keys).to eq([ :task ])
      end
    end
  end

  it "declares include_events as a boolean on the action" do
    definition = described_class.action_definitions.fetch("system_get_task")
    expect(definition[:parameters][:include_events]).to include(type: "boolean", required: false)
  end
end
