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
end
