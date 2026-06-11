# frozen_string_literal: true

require "rails_helper"

# Audit F5-04 — the module deployment pipeline (staged
# prepare/transfer/install/configure/activate with rollback over SSH) had
# zero spec coverage despite being the write path that mutates fleet nodes.
RSpec.describe System::ModuleCommitService do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform) }
  let(:node)     { create(:system_node, account: account, node_template: template) }
  let(:instance) { create(:system_node_instance, :running, node: node) }
  let(:node_module) do
    create(:system_node_module, account: account, node_platform: platform,
           category: category, name: "nginx-commit", enabled: true)
  end

  let(:ok_ssh) { System::Runtime::Result.ok(data: { stdout: "", exit_code: 0 }) }

  def commit!
    described_class.commit(node_module: node_module, instance: instance)
  end

  describe "successful commit" do
    before do
      allow(System::SshExecutionService).to receive(:execute).and_return(ok_ssh)
      allow(System::SshExecutionService).to receive(:scp_file).and_return(ok_ssh)
    end

    it "runs all five stages, records the commit, and returns per-stage durations" do
      result = commit!

      expect(result.success?).to be true
      expect(result.data[:commit_id]).to match(/\Acommit-\d{14}-\h{8}\z/)
      expect(result.data[:stages].keys)
        .to eq(%w[prepare transfer install configure activate])
      expect(result.data[:stages].values).to all(include(:duration))
      expect(result.data[:duration]).to be_a(Numeric)

      assignment = System::NodeModuleAssignment.find_by(node: node, node_module: node_module)
      expect(assignment.config.dig("last_commit", "commit_id")).to eq(result.data[:commit_id])
      expect(assignment.config.dig("last_commit", "instance_id")).to eq(instance.id)
      expect(assignment.config.dig("last_commit", "success")).to be true
    end

    it "cleans up the local staging directory" do
      result = commit!

      staging = Rails.root.join("tmp", "commits", result.data[:commit_id])
      expect(File.exist?(staging)).to be false
    end

    it "refuses a disabled module before staging anything" do
      node_module.update!(enabled: false)

      result = commit!

      expect(result.success?).to be false
      expect(result.error).to match(/disabled/i)
    end

    it "refuses a non-active instance" do
      instance.update_columns(status: "error")

      result = commit!

      expect(result.success?).to be false
      expect(result.error).to match(/not running/i)
    end
  end

  describe "stage_transfer failure (scp error)" do
    before do
      # remote staging prep succeeds; the scp itself fails.
      allow(System::SshExecutionService).to receive(:execute).and_return(ok_ssh)
      allow(System::SshExecutionService).to receive(:scp_file).and_return(
        System::Runtime::Result.err(error: "connection refused",
                                    data: { exit_code: 1, stderr: "connection refused" })
      )
    end

    it "fails the commit with the stage + scp diagnostics" do
      result = commit!

      expect(result.success?).to be false
      expect(result.error).to match(/Commit failed at transfer/i)
      expect(result.error).to match(/connection refused/)
      expect(result.data[:stage]).to eq("transfer")
    end

    it "leaves no orphan staging directory behind" do
      commit!

      commits_root = Rails.root.join("tmp", "commits")
      orphans = Dir.glob(File.join(commits_root, "commit-*"))
      expect(orphans).to be_empty,
        "stage failure orphaned staging dir(s): #{orphans.inspect}"
    end
  end

  describe "rollback of completed stages" do
    # A copy path stages the module file onto temporary high-speed storage
    # (e.g. tmpfs) BEFORE mounting, for performance — it is not generic
    # config-file deployment. Rollback removing the staged copy is therefore
    # the correct unwind. The real association: NodeModule belongs_to
    # :copy_path (singular).
    let!(:copy_path) do
      cp = create(:system_node_module_copy_path, account: account,
                  source_path: "files/nginx-mod.erofs",
                  destination_path: "/dev/shm/powernode/modules/nginx-mod.erofs")
      node_module.update!(copy_path: cp)
      cp
    end

    it "unwinds install (rm -rf of copied destinations) when configure fails" do
      issued = []
      allow(System::SshExecutionService).to receive(:scp_file).and_return(ok_ssh)
      allow(System::SshExecutionService).to receive(:execute) do |instance:, command:, **_kw|
        issued << command
        ok_ssh
      end
      # Force the configure stage to fail via a mask whose sed apply errors.
      node_module.update!(mask: { "/etc/app/app.conf" => { "KEY" => "VALUE" } })
      allow(System::SshExecutionService).to receive(:execute)
        .with(instance: anything, command: a_string_starting_with("sed"), sudo: true) do |instance:, command:, **_kw|
          issued << command
          System::Runtime::Result.err(error: "sed: no such file",
                                      data: { stderr: "sed: no such file" })
        end

      result = commit!

      expect(result.success?).to be false
      expect(result.error).to match(/Commit failed at configure/i)
      # install's rollback removes the staged high-speed copy
      expect(issued).to include("rm -rf /dev/shm/powernode/modules/nginx-mod.erofs")
    end
  end

  describe "mask sed escaping (operator-supplied values over SSH)" do
    let(:service) { described_class.new }

    it "escapes the replacement-side specials: backslash, delimiter, ampersand, newline" do
      expect(service.send(:sed_escape_replacement, 'C:\\path')).to eq('C:\\\\path')
      expect(service.send(:sed_escape_replacement, "a|b")).to eq('a\\|b')
      expect(service.send(:sed_escape_replacement, "user&co")).to eq('user\\&co')
      expect(service.send(:sed_escape_replacement, "l1\nl2")).to eq('l1\\nl2')
      # `/` needs NO escaping — the sed delimiter is `|` precisely so paths pass through.
      expect(service.send(:sed_escape_replacement, "/usr/local/bin")).to eq("/usr/local/bin")
    end

    it "escapes regex metacharacters on the search side" do
      expect(service.send(:sed_escape_search, "KEY.NAME")).to eq('KEY\\.NAME')
      expect(service.send(:sed_escape_search, "A*B")).to eq('A\\*B')
      expect(service.send(:sed_escape_search, "X[1]")).to eq('X\\[1\\]')
    end

    it "builds a single-line, fully shell-escaped sed command per file" do
      node_module.update!(mask: {
        "/etc/app.conf" => {
          "DB_URL" => "postgres://u:p@h/db?x=1&y=2",
          "BANNER" => "line1\nline2"
        }
      })
      captured = nil
      allow(System::SshExecutionService).to receive(:execute) do |instance:, command:, sudo:|
        captured = command
        expect(sudo).to be true
        ok_ssh
      end

      summary = service.send(:apply_mask_configuration, node_module, instance)

      expect(summary[:masked]).to eq(["/etc/app.conf"])
      expect(summary[:errors]).to be_empty
      expect(captured).to start_with("sed -i")
      expect(captured).to include("/etc/app.conf")
      # The raw newline in BANNER must never reach the remote shell unescaped.
      expect(captured).not_to include("\n")
      # The & in DB_URL is escaped so sed cannot expand it to the match.
      expect(captured).to include(Shellwords.escape('s|{{DB_URL}}|postgres://u:p@h/db?x=1\\&y=2|g'))
    end

    it "fails only the offending file and reports per-file errors" do
      node_module.update!(mask: { "/etc/missing.conf" => { "K" => "V" } })
      allow(System::SshExecutionService).to receive(:execute).and_return(
        System::Runtime::Result.err(error: "sed failed", data: { stderr: "no such file" })
      )

      summary = service.send(:apply_mask_configuration, node_module, instance)

      expect(summary[:masked]).to be_empty
      expect(summary[:errors]).to contain_exactly(
        hash_including(path: "/etc/missing.conf", error: "no such file")
      )
    end
  end
end
