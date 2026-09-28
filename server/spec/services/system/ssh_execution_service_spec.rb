# frozen_string_literal: true

require "rails_helper"
require "open3"

# Audit F5-01 — the single SSH/SCP substrate (module commit, instance/node
# maintenance, code deploy, ACME lego client, runtime executor) had zero
# direct specs; it appeared in spec/ only as a mock.
RSpec.describe System::SshExecutionService do
  let(:account)  { create(:account) }
  let(:node)     { create(:system_node, account: account) }
  let(:instance) { create(:system_node_instance, :running, node: node) }

  let(:ok_status)   { instance_double(Process::Status, exitstatus: 0) }
  let(:fail_status) { instance_double(Process::Status, exitstatus: 7) }

  before do
    allow(instance).to receive(:ssh_ip_address).and_return("10.0.0.9")
    allow(instance).to receive(:key).and_return("PRIVATE-KEY-MATERIAL")
  end

  def execute!(**kw)
    described_class.new.execute(instance: instance, command: "uptime", **kw)
  end

  # F5-01 (discovered writing these specs) — NodeInstance#ssh_ip_address was
  # called by this service + the internal serializer but NEVER DEFINED:
  # every real SSH execution raised NoMethodError, swallowed into
  # Runtime::Result.err. Pin the resolution chain.
  describe "host resolution" do
    it "prefers vpn over private over public addresses" do
      bare = create(:system_node_instance, :running, node: node)
      expect(bare.ssh_ip_address).to eq(bare.private_ip_address)

      bare.update_columns(vpn_ip_address: "100.64.0.5")
      expect(bare.reload.ssh_ip_address).to eq("100.64.0.5")

      bare.update_columns(vpn_ip_address: nil, private_ip_address: nil)
      expect(bare.reload.ssh_ip_address).to eq(bare.public_ip_address)
    end
  end

  # F5-01 case 1 — argv safety: ssh/scp build the destination as
  # "#{user}@#{host}"; a value beginning with '-' would be parsed by ssh as
  # an OPTION (e.g. -oProxyCommand=...) instead of a destination. admin_user
  # is operator-settable JSONB config, so this must be rejected before argv.
  describe "argv injection guard" do
    before { allow(Open3).to receive(:capture3).and_return([ "", "", ok_status ]) }

    it "rejects a user beginning with '-' instead of passing it to ssh" do
      allow(instance).to receive(:admin_user).and_return("-oProxyCommand=evil")

      result = execute!

      expect(result.success?).to be(false)
      expect(Open3).not_to have_received(:capture3)
    end

    it "rejects a host beginning with '-' instead of passing it to ssh" do
      allow(instance).to receive(:ssh_ip_address).and_return("-oProxyCommand=evil")

      result = execute!

      expect(result.success?).to be(false)
      expect(Open3).not_to have_received(:capture3)
    end

    it "rejects an scp destination user beginning with '-'" do
      allow(instance).to receive(:admin_user).and_return("-oProxyCommand=evil")

      result = described_class.new.scp_file(
        instance: instance, local_path: __FILE__, remote_path: "/tmp/x"
      )

      expect(result.success?).to be(false)
      expect(Open3).not_to have_received(:capture3)
    end

    it "still executes for a normal user@host" do
      allow(instance).to receive(:admin_user).and_return("pnadmin")

      result = execute!

      expect(result.success?).to be(true)
      expect(Open3).to have_received(:capture3) do |*argv|
        expect(argv.last(2)).to eq([ "pnadmin@10.0.0.9", "sudo uptime" ])
      end
    end
  end

  # F5-01 case 3 — non-zero exit returns Result.err preserving the process
  # output triple.
  describe "non-zero exit codes" do
    it "returns Result.err with stdout/stderr/exit_code preserved" do
      allow(Open3).to receive(:capture3).and_return([ "partial out", "boom", fail_status ])

      result = execute!

      expect(result.success?).to be(false)
      expect(result.error).to include("status 7")
      expect(result.data[:stdout]).to eq("partial out")
      expect(result.data[:stderr]).to eq("boom")
      expect(result.data[:exit_code]).to eq(7)
    end
  end

  # F5-01 case 4 — the private key tempfile must be unlinked even when Open3
  # raises mid-execution (Tempfile#path is nil once unlinked).
  describe "key tempfile hygiene" do
    it "unlinks the key file when Open3 raises" do
      created = []
      allow(Tempfile).to receive(:new).and_wrap_original do |m, *args|
        m.call(*args).tap { |tf| created << tf }
      end
      allow(Open3).to receive(:capture3).and_raise(IOError, "connection torn down")

      result = execute!

      expect(result.success?).to be(false)
      expect(created.size).to eq(1)
      expect(created.first.path).to be_nil
    end
  end

  # F5-01 case 2 — SYSTEM_SSH_ENABLED=false must never mock success outside
  # the test environment; in test env the mock keeps SSH-dependent specs
  # runnable without keys or network.
  describe "SYSTEM_SSH_ENABLED=false" do
    before do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("SYSTEM_SSH_ENABLED").and_return("false")
    end

    it "refuses with an SshError-backed failure outside the test env" do
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))

      result = execute!

      expect(result.success?).to be(false)
      expect(result.error).to include("SYSTEM_SSH_ENABLED")
      expect(result.error).not_to include("Mock")
    end

    it "returns the synthetic mock success in the test env" do
      result = execute!

      expect(result.success?).to be(true)
      expect(result.data[:stdout]).to include("Mock execution")
    end
  end

  # IMP-9ce0ed39c557 — .cleanse/#cleanse's only caller was the unrouted
  # ssh_cleanse controller action, removed alongside it (dead code with no
  # remaining door). .sync/#sync is untouched: System::NodeMaintenanceService
  # calls it for real.
  describe "cleanse removal" do
    it "no longer implements .cleanse or #cleanse" do
      expect(described_class).not_to respond_to(:cleanse)
      expect(described_class.new).not_to respond_to(:cleanse)
    end

    it "still implements .sync — a real caller elsewhere keeps it" do
      expect(described_class).to respond_to(:sync)
    end
  end

  # IMP-9ce0ed39c557 — the opt-in bounded runner for out-of-band exec. A
  # SEPARATE method from #execute (never called by any of its ~40 existing
  # in-process callers): those stay on Open3.capture3 with no deadline and
  # no output cap. This delegates the actual timeout/truncation MECHANICS to
  # System::BoundedCommandRunner (covered for real elsewhere,
  # bounded_command_runner_spec.rb) and is responsible only for its own
  # slice: host/key validation (shared with #execute) and the ssh argv,
  # stubbed here so this file stays about THIS class's contract.
  describe "#execute_bounded" do
    def execute_bounded!(**kw)
      described_class.new.execute_bounded(
        instance: instance, command: "uptime",
        timeout_seconds: 45, max_output_bytes: 1024, **kw
      )
    end

    let(:bounded_result) do
      System::BoundedCommandRunner::Result.new(
        stdout: "ok", stderr: "", exit_code: 0, timed_out: false, truncated: false
      )
    end

    before do
      allow(System::BoundedCommandRunner).to receive(:run).and_return(bounded_result)
    end

    it "builds the ssh argv with BatchMode and ServerAliveInterval and delegates to BoundedCommandRunner" do
      execute_bounded!

      expect(System::BoundedCommandRunner).to have_received(:run).with(
        array_including("ssh", "-o", "BatchMode=yes", a_string_matching(/\AServerAliveInterval=\d+\z/)),
        timeout_seconds: 45, max_output_bytes: 1024
      )
    end

    # IMP-9ce0ed39c557 review finding #3: the remote command must be wrapped
    # in `timeout -k` so the NODE enforces its own deadline independent of
    # what happens to the local ssh client (see
    # #execute_ssh_command_bounded's header comment). `sudo` wraps the
    # OUTSIDE of that wrapper — `sudo timeout -k 5 N sh -c '<command>'` — so
    # `timeout` itself runs as root and can signal a root-owned group.
    it "wraps the command in a remote `timeout -k` + sudo, not a bare sudo prefix" do
      execute_bounded!

      expect(System::BoundedCommandRunner).to have_received(:run).with(
        array_including("pnadmin@10.0.0.9", "sudo timeout -k 5 45 sh -c uptime"), anything
      )
    end

    it "does not sudo-prefix when sudo: false, but still wraps in timeout -k" do
      execute_bounded!(sudo: false)

      expect(System::BoundedCommandRunner).to have_received(:run).with(
        array_including("pnadmin@10.0.0.9", "timeout -k 5 45 sh -c uptime"), anything
      )
    end

    it "shell-escapes a command containing shell operators as ONE argument to `sh -c`" do
      execute_bounded!(command: "echo a && echo b")

      expect(System::BoundedCommandRunner).to have_received(:run).with(
        array_including("pnadmin@10.0.0.9", "sudo timeout -k 5 45 sh -c echo\\ a\\ \\&\\&\\ echo\\ b"), anything
      )
    end

    it "returns success with timed_out/truncated surfaced in data" do
      result = execute_bounded!

      expect(result.success?).to be true
      expect(result.data[:timed_out]).to be false
      expect(result.data[:truncated]).to be false
      expect(result.data[:stdout]).to eq("ok")
    end

    it "surfaces a timed-out run as a Result.err carrying timed_out: true" do
      allow(System::BoundedCommandRunner).to receive(:run).and_return(
        System::BoundedCommandRunner::Result.new(
          stdout: "partial", stderr: "", exit_code: nil, timed_out: true, truncated: false
        )
      )

      result = execute_bounded!

      expect(result.success?).to be false
      expect(result.data[:timed_out]).to be true
      expect(result.error).to match(/timed out/i)
    end

    it "surfaces truncated output as data even on an otherwise-successful run" do
      allow(System::BoundedCommandRunner).to receive(:run).and_return(
        System::BoundedCommandRunner::Result.new(
          stdout: "x" * 1024, stderr: "", exit_code: 0, timed_out: false, truncated: true
        )
      )

      result = execute_bounded!

      expect(result.success?).to be true
      expect(result.data[:truncated]).to be true
    end

    it "still validates argv-injection guards before ever calling BoundedCommandRunner" do
      allow(instance).to receive(:admin_user).and_return("-oProxyCommand=evil")

      result = execute_bounded!

      expect(result.success?).to be false
      expect(System::BoundedCommandRunner).not_to have_received(:run)
    end

    it "returns Result.err with no SSH key available, never reaching BoundedCommandRunner" do
      allow(instance).to receive(:key).and_return(nil)
      allow(instance).to receive_message_chain(:node, :ssh_key).and_return(nil)

      result = execute_bounded!

      expect(result.success?).to be false
      expect(System::BoundedCommandRunner).not_to have_received(:run)
    end

    it "falls back to the same synthetic mock as #execute when SSH is disabled in test env" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("SYSTEM_SSH_ENABLED").and_return("false")

      result = execute_bounded!

      expect(System::BoundedCommandRunner).not_to have_received(:run)
      expect(result.success?).to be true
      expect(result.data[:stdout]).to include("Mock execution")
      expect(result.data[:timed_out]).to be false
      expect(result.data[:truncated]).to be false
    end

    # Review finding #4/#9: the previous log-line coverage only stubbed
    # Rails.logger and asserted nothing about its arguments, so it could not
    # have failed even with the command text still logged. This captures the
    # REAL arguments #execute_bounded passes to Rails.logger.info, with a
    # distinctive command marker that would only appear here if it leaked,
    # and separately confirms logging still happened at all (so this cannot
    # pass merely because nothing was ever logged).
    it "never logs the command text on either log line" do
      marker = "echo super-secret-marker-9ce0ed"
      logged = []
      allow(Rails.logger).to receive(:info) { |msg| logged << msg }

      execute_bounded!(command: marker)

      expect(logged).not_to be_empty
      expect(logged.join("\n")).to include(instance.id.to_s)
      expect(logged.join("\n")).not_to include(marker)
    end

    it "refuses outside the test env when SSH is disabled, same as #execute" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("SYSTEM_SSH_ENABLED").and_return("false")
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))

      result = execute_bounded!

      expect(result.success?).to be false
      expect(result.error).to include("SYSTEM_SSH_ENABLED")
      expect(System::BoundedCommandRunner).not_to have_received(:run)
    end
  end
end
