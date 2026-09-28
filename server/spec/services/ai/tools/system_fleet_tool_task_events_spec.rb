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

    it "redacts a secret sitting past the per-string cap in both the truncated and the full copy" do
      cap = described_class::GET_ERROR_MESSAGE_LIMIT
      huge = ("x " * cap) + fake_password
      t = build_task(events: [ completed_event({ "log_tail" => huge }) ])

      r = call(task_id: t.id, include_events: true)
      tail = r[:data][:events].first["result"]["log_tail"]

      expect(tail.length).to be <= cap + "...[truncated]".length
      expect(tail).not_to include("FAKEhunter2FAKE")
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

    it "caps each string at the single-task error limit" do
      cap = described_class::GET_ERROR_MESSAGE_LIMIT
      t = build_task(events: [ completed_event({ "log_tail" => "y" * (cap * 3) }) ])

      r = call(task_id: t.id, include_events: true)

      expect(r[:data][:events].first["result"]["log_tail"]).to eq("#{'y' * cap}...[truncated]")
    end

    it "spends the total string budget newest-first, omitting the oldest strings once it is gone" do
      cap = described_class::GET_ERROR_MESSAGE_LIMIT
      fat = build_task(events: Array.new(described_class::TASK_EVENTS_LIMIT) { |i| completed_event({ "log_tail" => "z" * cap, "n" => i }) })

      r = call(task_id: fat.id, include_events: true)
      tails = r[:data][:events].map { |e| e["result"]["log_tail"] }

      expect(tails.last).to eq("z" * cap)
      expect(tails.first).to match(/omitted: event payload budget exhausted/)
      spent = tails.reject { |t| t.include?("omitted:") }.sum(&:length)
      expect(spent).to be <= described_class::TASK_EVENTS_MAX_CHARS
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
