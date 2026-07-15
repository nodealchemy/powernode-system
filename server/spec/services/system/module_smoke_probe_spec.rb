# frozen_string_literal: true

require "rails_helper"

# Campaign 019f6084 inc-E — dispatch/poll wiring. There is no live agent in
# these specs — every test either times out a genuinely-dispatched, never-
# completed task (poll_timeout_seconds stubbed to "0", the same
# bounded-retry-with-no-sleep pattern CiBuildOrchestrator's own spec uses
# for its correlate_timeout) or mocks System::Task.create! to return an
# already-completed task, since nothing in this process ever actually runs
# an agent-delegated command.
RSpec.describe System::ModuleSmokeProbe do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform) }
  let(:node)     { create(:system_node, account: account, node_template: template) }
  let(:instance) { create(:system_node_instance, :running, node: node, last_heartbeat_at: 30.seconds.ago) }

  let(:node_module) do
    create(:system_node_module, account: account, node_platform: platform, category: category,
           name: "nginx-fresh", file_spec: %w[/usr/sbin/nginx /usr/lib/nginx/modules/** /etc/nginx/])
  end

  before do
    create(:system_module_service, node_module: node_module, name: "nginx",
                                    health_endpoint: "/healthz", health_method: "GET")
  end

  def run_probe
    described_class.run(instance: instance, node_module: node_module, base_os_module_name: "base-os-ubuntu-noble")
  end

  describe "#run — no reachable agent" do
    it "returns an unavailable result and never dispatches a task when the instance has no heartbeat" do
      instance.update!(last_heartbeat_at: nil)

      result = nil
      expect { result = run_probe }.not_to change { System::Task.count }

      expect(result.ok?).to be false
      expect(result.checks.map(&:name)).to eq(described_class::CHECKS)
      expect(result.checks).to all(satisfy { |c| c.detail.match?(/unavailable/) })
    end

    it "treats a stale heartbeat the same as no agent" do
      instance.update!(last_heartbeat_at: 10.minutes.ago)

      result = nil
      expect { result = run_probe }.not_to change { System::Task.count }
      expect(result.ok?).to be false
    end
  end

  describe "#run — dispatch" do
    before do
      allow(::SiteSetting).to receive(:get).and_call_original
      allow(::SiteSetting).to receive(:get).with("system.module_smoke.poll_timeout_seconds").and_return("0")
    end

    it "dispatches a probe.module_smoke task with the right target + options (then times out — nothing completes it)" do
      run_probe

      task = System::Task.find_by(operable: instance, command: "probe.module_smoke")
      expect(task).not_to be_nil
      expect(task.account).to eq(account)
      expect(task.options["module"]).to eq("nginx-fresh")
      expect(task.options["module_id"]).to eq(node_module.id)
      expect(task.options["base_os"]).to eq("base-os-ubuntu-noble")
      expect(task.options["checks"]).to eq(described_class::CHECKS)
      expect(task.options["services"]).to eq([ "nginx" ])
      expect(task.options["health_checks"]).to eq(
        [ { "service" => "nginx", "endpoint" => "/healthz", "method" => "GET" } ]
      )
      # Glob ("/usr/lib/nginx/modules/**") and directory ("/etc/nginx/")
      # file_spec entries are excluded — only concrete absolute paths are
      # usable ldd candidates (see #concrete_absolute_path?'s doc).
      expect(task.options["elf_candidates"]).to eq([ "/usr/sbin/nginx" ])
    end
  end

  describe "#run — timeout" do
    before do
      allow(::SiteSetting).to receive(:get).and_call_original
      allow(::SiteSetting).to receive(:get).with("system.module_smoke.poll_timeout_seconds").and_return("0")
    end

    it "returns an unavailable result when the dispatched task never completes" do
      result = run_probe

      expect(result.ok?).to be false
      expect(result.checks.map(&:name)).to eq(described_class::CHECKS)
      expect(result.checks).to all(satisfy { |c| c.detail.match?(/timed out/) })

      task = System::Task.find_by(operable: instance, command: "probe.module_smoke")
      expect(task.status).to eq("pending")
    end
  end

  describe "#run — completion" do
    def completed_task(result_payload)
      create(:system_task, :complete, account: account, operable: instance, command: "probe.module_smoke",
                            events: [ { "type" => "completed", "message" => "done", "result" => result_payload,
                                       "timestamp" => Time.current.iso8601 } ])
    end

    it "parses a passing report from the completed task's result" do
      task = completed_task(
        "ok" => true,
        "checks" => [
          { "name" => "unit_active", "ok" => true, "detail" => "active" },
          { "name" => "health_endpoint", "ok" => true, "detail" => "http_status=200" },
          { "name" => "ldd_closure", "ok" => true, "detail" => "resolved" }
        ]
      )
      allow(System::Task).to receive(:create!).and_return(task)

      result = run_probe

      expect(result.ok?).to be true
      expect(result.checks.size).to eq(3)
      expect(result.checks.map(&:name)).to eq(described_class::CHECKS)
      expect(result.checks).to all(have_attributes(pass: true))
    end

    it "parses a failing report and surfaces the failing check's own detail" do
      task = completed_task(
        "ok" => false,
        "checks" => [
          { "name" => "unit_active", "ok" => true, "detail" => "active" },
          { "name" => "health_endpoint", "ok" => false, "detail" => "http_status=503" },
          { "name" => "ldd_closure", "ok" => true, "detail" => "resolved" }
        ]
      )
      allow(System::Task).to receive(:create!).and_return(task)

      result = run_probe

      expect(result.ok?).to be false
      failing = result.checks.find { |c| c.name == "health_endpoint" }
      expect(failing.pass).to be false
      expect(failing.detail).to eq("http_status=503")
    end

    it "returns an unavailable result when the task itself failed (e.g. unknown_command)" do
      task = create(:system_task, :failed, account: account, operable: instance, command: "probe.module_smoke",
                                   error_message: "unknown_command: probe.module_smoke")
      allow(System::Task).to receive(:create!).and_return(task)

      result = run_probe

      expect(result.ok?).to be false
      expect(result.checks).to all(satisfy { |c| c.detail.match?(/failed/) })
    end
  end
end
