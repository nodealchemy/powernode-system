# frozen_string_literal: true

require "rails_helper"

# Audit F5-08 — InstanceMaintenanceService (483 lines, exposed through
# worker_api + internal node_instances controllers) had zero spec
# references despite ~100 lines of hand-rolled df/free/top/ss parsers
# that mutate instance.config.
RSpec.describe System::InstanceMaintenanceService do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform) }
  let(:node)     { create(:system_node, account: account, node_template: template) }
  let(:instance) { create(:system_node_instance, :running, node: node) }
  let(:service)  { described_class.new }

  describe "#run_maintenance" do
    it "refuses a non-running instance" do
      instance.update_columns(status: "error")

      result = described_class.run_maintenance(instance: instance)

      expect(result.success?).to be false
      expect(result.error).to match(/not running/i)
    end

    it "filters unknown task names against the MAINTENANCE_TASKS allowlist" do
      allow(service).to receive(:task_health_check).and_return({ success: true })

      result = service.run_maintenance(instance: instance,
                                       tasks: %w[health_check rm_dash_rf bogus])

      expect(result.success?).to be true
      expect(result.data[:tasks_run]).to eq(1)
      expect(result.data[:results].keys).to eq(%w[health_check])
    end

    it "aggregates per-task failures without aborting remaining tasks and persists to instance.config" do
      allow(service).to receive(:task_health_check).and_return({ success: false, error: "ssh unreachable" })
      allow(service).to receive(:task_memory_check).and_return({ success: true })

      result = service.run_maintenance(instance: instance,
                                       tasks: %w[health_check memory_check])

      expect(result.success?).to be false
      expect(result.error).to match(/1 task\(s\) failed/)
      expect(result.data[:tasks_succeeded]).to eq(1)
      expect(result.data[:tasks_failed]).to eq(1)
      expect(result.data[:results]["memory_check"][:success]).to be true

      record = instance.reload.config["last_maintenance"]
      expect(record["tasks"]).to contain_exactly("health_check", "memory_check")
      expect(record["success"]).to be false
      expect(record["ran_at"]).to be_present
    end

    it "converts a raising task into a recorded failure and still runs the rest" do
      allow(service).to receive(:task_health_check).and_raise(RuntimeError, "ssh exploded")
      allow(service).to receive(:task_memory_check).and_return({ success: true })

      result = nil
      expect {
        result = service.run_maintenance(instance: instance,
                                         tasks: %w[health_check memory_check])
      }.not_to raise_error

      expect(result.success?).to be false
      expect(result.data[:results]["health_check"][:success]).to be false
      expect(result.data[:results]["health_check"][:error]).to match(/ssh exploded/)
      expect(result.data[:results]["memory_check"][:success]).to be true
      expect(instance.reload.config["last_maintenance"]["success"]).to be false
    end
  end

  describe "#task_service_status with module-declared services" do
    let(:node_module) do
      create(:system_node_module, account: account, node_platform: platform,
             category: category, name: "web-stack", enabled: true,
             file_spec: { "services" => [ "nginx" ] })
    end

    before do
      create(:system_node_module_assignment, node: node, node_module: node_module)
      allow(service).to receive(:ssh_run)
        .and_return(System::Runtime::Result.ok(data: { stdout: "active\n", exit_code: 0 }))
    end

    # The real association is NodeModule#copy_path (singular belongs_to);
    # includes(node_module: :node_module_copy_paths) raised
    # AssociationNotFoundError whenever the node had any assignment —
    # killing the whole maintenance run, not just this task.
    it "collects services from assigned module file_specs and checks them" do
      summary = service.send(:task_service_status, instance, {})

      expect(summary[:success]).to be true
      expect(summary[:services]).to include("nginx" => "running",
                                            "sshd" => "running",
                                            "cron" => "running")
      expect(summary[:failed]).to be_empty
    end
  end

  describe "output parsers" do
    describe "#parse_df_output" do
      it "parses normal, tmpfs, and >100% lines, skipping the header and short lines" do
        output = <<~DF
          Filesystem      Size  Used Avail Use% Mounted on
          /dev/vda1        40G   35G  2.9G  93% /
          tmpfs           3.9G     0  3.9G   0% /dev/shm
          /dev/mapper/big 100G  104G     0 104% /data
          incomplete-line
        DF

        rows = service.send(:parse_df_output, output)

        expect(rows.size).to eq(3)
        expect(rows[0]).to include(mount: "/dev/vda1", used_percent: 93)
        expect(rows[1]).to include(mount: "tmpfs", used_percent: 0)
        expect(rows[2]).to include(used_percent: 104)
      end

      it "returns [] for nil output" do
        expect(service.send(:parse_df_output, nil)).to eq([])
      end
    end

    describe "#parse_free_output" do
      it "parses the Mem: row and computes used percent" do
        output = <<~FREE
                        total        used        free      shared  buff/cache   available
          Mem:           8000        2000         512         123        4444        4533
          Swap:          2047           0        2047
        FREE

        mem = service.send(:parse_free_output, output)

        expect(mem).to include(total_mb: 8000, used_mb: 2000, available_mb: 4533)
        expect(mem[:used_percent]).to eq(25.0)
      end

      it "returns {} when no Mem: line is present" do
        expect(service.send(:parse_free_output, "garbage\n")).to eq({})
      end

      it "guards the percent division when total is zero" do
        mem = service.send(:parse_free_output, "Mem: 0 0 0 0 0 0\n")
        expect(mem[:used_percent]).to eq(0)
      end
    end

    describe "#parse_swap_info" do
      it "parses /proc/swaps-style output" do
        output = <<~SWAP
          Filename   Type  Size     Used  Priority
          /swapfile  file  2097148  1048574  -2
        SWAP

        swap = service.send(:parse_swap_info, output)

        expect(swap).to include(device: "/swapfile", type: "file",
                                size_kb: 2_097_148, used_kb: 1_048_574)
        expect(swap[:used_percent]).to eq(50.0)
      end

      it "returns nil when no swap is configured (header only)" do
        expect(service.send(:parse_swap_info, "Filename Type Size Used Priority\n")).to be_nil
      end

      it "returns nil for a malformed data line" do
        expect(service.send(:parse_swap_info, "header\n/swapfile file\n")).to be_nil
      end
    end

    describe "#parse_top_processes" do
      it "parses ps aux rows including kernel threads, skipping short lines" do
        output = <<~PS
          USER PID %CPU %MEM VSZ RSS TTY STAT START TIME COMMAND
          root 1234 42.5 3.1 123456 65432 ? Ssl 10:00 1:23 /usr/bin/ruby server.rb --port 3000
          root 23 0.0 0.0 0 0 ? S 10:00 0:00 [kworker/0:1]
          short line
        PS

        procs = service.send(:parse_top_processes, output)

        expect(procs.size).to eq(2)
        expect(procs[0]).to include(user: "root", pid: 1234, cpu_percent: 42.5, mem_percent: 3.1)
        expect(procs[0][:command]).to eq("/usr/bin/ruby server.rb --port 3000")
        expect(procs[1][:command]).to eq("[kworker/0:1]")
      end
    end

    describe "#parse_long_running_processes" do
      it "parses pid/elapsed/command rows" do
        output = <<~PS
          PID ELAPSED COMMAND
          999 10-04:20:11 /usr/sbin/rsyslogd -n
        PS

        procs = service.send(:parse_long_running_processes, output)

        expect(procs).to contain_exactly(
          hash_including(pid: 999, elapsed: "10-04:20:11", command: "/usr/sbin/rsyslogd -n")
        )
      end
    end

    describe "#parse_interfaces" do
      it "parses interface/address pairs and skips malformed lines" do
        rows = service.send(:parse_interfaces, "eth0 10.0.0.5/24\nlo 127.0.0.1/8\nnoaddr\n")

        expect(rows).to eq([
          { interface: "eth0", address: "10.0.0.5/24" },
          { interface: "lo", address: "127.0.0.1/8" }
        ])
      end
    end
  end
end
