# frozen_string_literal: true

require "rails_helper"

# AI-Driven Provisioning M3 — slice A (Run My Code).
#
# CodeDeployService delegates every shell-out to System::SshExecutionService,
# so these specs stub that single boundary rather than reaching for Net::SSH
# or Open3 directly. Each test wires a per-command response based on the
# command string the service emits, then asserts both:
#
#   - the public envelope shape ({ success:, commit_sha:, public_url:, error: })
#   - that key plumbing commands (systemd unit write, daemon-reload, deploy
#     key install, runtime-specific dependency install) made it onto the wire
RSpec.describe System::CodeDeployService do
  let(:node_instance) do
    instance_double(
      "System::NodeInstance",
      name: "deploy-target-1",
      public_ip_address: "203.0.113.10"
    )
  end

  let(:repo_url) { "https://github.com/example/discord-bot.git" }
  let(:branch)   { "main" }

  # Re-usable command-router. Sub-specs override individual rules and fall
  # back to a permissive default for everything else.
  def stub_ssh(rules)
    allow(::System::SshExecutionService).to receive(:execute) do |args|
      cmd = args[:command].to_s
      rule = rules.find { |matcher, _| matcher === cmd }
      result = rule ? rule.last.call(cmd) : System::Runtime::Result.ok(data: { stdout: "", stderr: "", exit_code: 0 })
      result
    end
  end

  def ok_result(stdout: "", exit_code: 0)
    System::Runtime::Result.ok(data: { stdout: stdout, stderr: "", exit_code: exit_code })
  end

  def err_result(error: "Command exited with status 1", stderr: "", exit_code: 1)
    System::Runtime::Result.err(error: error, data: { stdout: "", stderr: stderr, exit_code: exit_code })
  end

  before do
    # Default everything-succeeds so tests that don't care about a specific
    # branch don't need to enumerate every command.
    allow(::System::SshExecutionService).to receive(:execute).and_return(
      ok_result(stdout: "")
    )
  end

  describe ".call" do
    context "happy path with public Node.js repo" do
      before do
        stub_ssh([
          [ /git rev-parse HEAD/, ->(_cmd) { ok_result(stdout: "abc123def456\n") } ],
          [ /test -f.*package\.json/, ->(_cmd) { ok_result } ],
          [ /test -f/, ->(_cmd) { err_result(error: "no such file") } ]
        ])
      end

      it "returns success: true with commit_sha and derived public_url" do
        result = described_class.call(node_instance: node_instance, repo_url: repo_url)

        expect(result[:success]).to eq(true)
        expect(result[:commit_sha]).to eq("abc123def456")
        expect(result[:public_url]).to eq("http://203.0.113.10")
        expect(result[:error]).to be_nil
      end

      it "writes the systemd unit, runs daemon-reload, and enables the service" do
        captured = []
        allow(::System::SshExecutionService).to receive(:execute) do |args|
          captured << args[:command]
          cmd = args[:command].to_s
          if cmd.match?(/git rev-parse HEAD/)
            ok_result(stdout: "abc123\n")
          elsif cmd.match?(/test -f.*package\.json/)
            ok_result
          elsif cmd.match?(/test -f/)
            err_result
          else
            ok_result
          end
        end

        described_class.call(node_instance: node_instance, repo_url: repo_url)

        joined = captured.join("\n")
        expect(joined).to include("/etc/systemd/system/powernode-app.service")
        expect(joined).to include("ExecStart=/usr/bin/npm start")
        expect(joined).to include("WorkingDirectory=/opt/app")
        expect(joined).to include("systemctl daemon-reload")
        expect(joined).to include("systemctl enable --now powernode-app")
      end

      it "runs npm install with --omit=dev for the nodejs runtime" do
        captured = []
        allow(::System::SshExecutionService).to receive(:execute) do |args|
          captured << args[:command]
          cmd = args[:command].to_s
          if cmd.match?(/git rev-parse HEAD/)
            ok_result(stdout: "abc\n")
          elsif cmd.match?(/test -f.*package\.json/)
            ok_result
          elsif cmd.match?(/test -f/)
            err_result
          else
            ok_result
          end
        end

        described_class.call(node_instance: node_instance, repo_url: repo_url)

        expect(captured.any? { |c| c.to_s.include?("npm install --omit=dev") }).to be true
      end
    end

    context "private repo with deploy_key" do
      let(:deploy_key) do
        "-----BEGIN OPENSSH PRIVATE KEY-----\nFAKE\n-----END OPENSSH PRIVATE KEY-----"
      end

      it "drops the key at /root/.ssh/id_ed25519 with mode 0600 and adds github to known_hosts" do
        captured = []
        allow(::System::SshExecutionService).to receive(:execute) do |args|
          captured << args[:command]
          cmd = args[:command].to_s
          if cmd.match?(/git rev-parse HEAD/)
            ok_result(stdout: "deadbeef\n")
          elsif cmd.match?(/test -f.*package\.json/)
            ok_result
          elsif cmd.match?(/test -f/)
            err_result
          else
            ok_result
          end
        end

        result = described_class.call(
          node_instance: node_instance,
          repo_url: "git@github.com:example/private.git",
          deploy_key: deploy_key
        )

        expect(result[:success]).to eq(true)
        joined = captured.join("\n")
        expect(joined).to include("/root/.ssh/id_ed25519")
        expect(joined).to include("chmod 600 /root/.ssh/id_ed25519")
        expect(joined).to include("ssh-keyscan")
        expect(joined).to include("github.com")
      end

      it "skips the deploy-key install branch when no key is supplied" do
        captured = []
        allow(::System::SshExecutionService).to receive(:execute) do |args|
          captured << args[:command]
          cmd = args[:command].to_s
          if cmd.match?(/git rev-parse HEAD/)
            ok_result(stdout: "f00\n")
          elsif cmd.match?(/test -f.*package\.json/)
            ok_result
          elsif cmd.match?(/test -f/)
            err_result
          else
            ok_result
          end
        end

        described_class.call(node_instance: node_instance, repo_url: repo_url)

        expect(captured.none? { |c| c.to_s.include?("/root/.ssh/id_ed25519") }).to be true
      end
    end

    context "runtime auto-detect for python (app.py present)" do
      it "writes ExecStart=python3 app.py and runs pip install" do
        captured = []
        allow(::System::SshExecutionService).to receive(:execute) do |args|
          captured << args[:command]
          cmd = args[:command].to_s
          if cmd.match?(/git rev-parse HEAD/)
            ok_result(stdout: "py01\n")
          elsif cmd.match?(/test -f.*package\.json/)
            err_result
          elsif cmd.match?(/test -f.*requirements\.txt/)
            ok_result
          elsif cmd.match?(/test -f.*app\.py/)
            ok_result
          elsif cmd.match?(/test -f/)
            err_result
          else
            ok_result
          end
        end

        result = described_class.call(node_instance: node_instance, repo_url: "https://github.com/example/django-app.git")

        expect(result[:success]).to eq(true)
        joined = captured.join("\n")
        expect(joined).to include("ExecStart=python3 app.py")
        expect(joined).to include("pip install -r requirements.txt")
      end
    end

    context "explicit start_command supplied" do
      it "uses the operator-supplied command verbatim instead of auto-detecting" do
        captured = []
        allow(::System::SshExecutionService).to receive(:execute) do |args|
          captured << args[:command]
          cmd = args[:command].to_s
          if cmd.match?(/git rev-parse HEAD/)
            ok_result(stdout: "f00\n")
          elsif cmd.match?(/test -f.*package\.json/)
            ok_result
          elsif cmd.match?(/test -f/)
            err_result
          else
            ok_result
          end
        end

        result = described_class.call(
          node_instance: node_instance,
          repo_url: repo_url,
          start_command: "node dist/server.js --port 3000"
        )

        expect(result[:success]).to eq(true)
        joined = captured.join("\n")
        expect(joined).to include("ExecStart=node dist/server.js --port 3000")
        # The auto-detected /usr/bin/npm start MUST NOT show up alongside.
        expect(joined).not_to include("ExecStart=/usr/bin/npm start")
      end
    end

    context "git clone fails (auth failure)" do
      it "returns success: false with an error message — no exception escapes" do
        allow(::System::SshExecutionService).to receive(:execute) do |args|
          if args[:command].to_s.include?("git clone")
            err_result(error: "Command exited with status 128", stderr: "fatal: Authentication failed", exit_code: 128)
          else
            ok_result
          end
        end

        result = described_class.call(node_instance: node_instance, repo_url: "https://github.com/private/repo.git")

        expect(result[:success]).to eq(false)
        expect(result[:error]).to include("git clone")
        expect(result[:commit_sha]).to be_nil
      end
    end

    context "no detectable runtime" do
      it "returns success: false explaining the failure" do
        allow(::System::SshExecutionService).to receive(:execute) do |args|
          cmd = args[:command].to_s
          if cmd.match?(/git rev-parse HEAD/)
            ok_result(stdout: "f00\n")
          elsif cmd.match?(/test -f/)
            err_result
          else
            ok_result
          end
        end

        result = described_class.call(node_instance: node_instance, repo_url: repo_url)

        expect(result[:success]).to eq(false)
        expect(result[:error]).to match(/Cannot detect runtime/i)
      end
    end

    context "input validation" do
      it "returns success: false when node_instance is nil" do
        result = described_class.call(node_instance: nil, repo_url: repo_url)
        expect(result[:success]).to eq(false)
        expect(result[:error]).to match(/node_instance required/i)
      end

      it "returns success: false when repo_url is blank" do
        result = described_class.call(node_instance: node_instance, repo_url: "")
        expect(result[:success]).to eq(false)
        expect(result[:error]).to match(/repo_url required/i)
      end
    end

    context "branch override" do
      it "passes the operator-supplied branch through to git clone" do
        captured = []
        allow(::System::SshExecutionService).to receive(:execute) do |args|
          captured << args[:command]
          cmd = args[:command].to_s
          if cmd.match?(/git rev-parse HEAD/)
            ok_result(stdout: "abc\n")
          elsif cmd.match?(/test -f.*package\.json/)
            ok_result
          elsif cmd.match?(/test -f/)
            err_result
          else
            ok_result
          end
        end

        described_class.call(node_instance: node_instance, repo_url: repo_url, branch: "feature/x")

        expect(captured.any? { |c| c.to_s.include?("--branch 'feature/x'") }).to be true
      end
    end
  end

  # Compensating action paired with .call — invoked by Slice B's
  # DeployAppCodeExecutor#rollback_deploy_app_code when a deploy step needs
  # to be undone.
  describe ".tear_down" do
    it "stops + disables the systemd unit, removes the unit file, and clears /opt/app" do
      captured = []
      allow(::System::SshExecutionService).to receive(:execute) do |args|
        captured << args[:command]
        ok_result
      end

      result = described_class.tear_down(node_instance: node_instance)

      expect(result).to eq(success: true, error: nil)
      script = captured.join("\n")
      expect(script).to include("systemctl stop powernode-app")
      expect(script).to include("systemctl disable powernode-app")
      expect(script).to include("rm -f /etc/systemd/system/powernode-app.service")
      expect(script).to include("rm -rf /opt/app")
      expect(script).to include("systemctl daemon-reload")
    end

    it "returns success: false with an error when the SSH transport fails" do
      allow(::System::SshExecutionService).to receive(:execute).and_return(
        err_result(error: "Command exited with status 255", stderr: "ssh: connection refused", exit_code: 255)
      )

      result = described_class.tear_down(node_instance: node_instance)

      expect(result[:success]).to be false
      expect(result[:error]).to match(/Command exited|ssh|status 255/)
    end

    it "swallows StandardError and returns failure (never raises)" do
      allow(::System::SshExecutionService).to receive(:execute).and_raise(StandardError, "boom")

      result = described_class.tear_down(node_instance: node_instance)

      expect(result[:success]).to be false
      expect(result[:error]).to match(/boom/)
    end

    it "raises ArgumentError when node_instance is nil" do
      expect {
        described_class.tear_down(node_instance: nil)
      }.to raise_error(ArgumentError, /node_instance required/)
    end
  end
end
