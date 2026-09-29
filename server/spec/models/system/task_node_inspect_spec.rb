# frozen_string_literal: true

require "rails_helper"

# IMP-52762a704a3d — probe.node_inspect is a task command the agent runs as
# root, and System::Task#options is free-form JSONB that TasksController#create
# accepts from any holder of system.infra_tasks.create. The verb validates its
# options, but the model is the one chokepoint every producer passes through, so
# a row minted any other way is refused here too.
RSpec.describe System::Task, "probe.node_inspect options" do
  let(:account)  { create(:account) }
  let(:instance) { create(:system_node_instance, :running, account: account) }

  def build_task(options, command: "probe.node_inspect")
    described_class.new(account: account, operable: instance, command: command, status: "pending", options: options)
  end

  it "is a command the platform can mint" do
    expect(described_class::COMMANDS).to include("probe.node_inspect")
  end

  it "accepts each collector's declared options" do
    [ { "collector" => "routes" },
      { "collector" => "wg_status", "interface" => "wg0" },
      { "collector" => "nft", "scope" => "chains" },
      { "collector" => "journal", "unit" => "sshd.service", "lines" => 50 },
      { "collector" => "unit", "unit" => "sshd.service" },
      { "collector" => "caps", "unit" => "sshd.service" },
      { "collector" => "file_stat", "path" => "/etc/hostname" } ].each do |opts|
      expect(build_task(opts)).to be_valid, opts.inspect
    end
  end

  it "refuses a row whose options a collector would refuse" do
    [ {},
      { "collector" => "ssh", "command" => "id" },
      { "collector" => "routes", "command" => "id" },
      { "collector" => "wg_status", "interface" => "all" },
      { "collector" => "journal", "unit" => "sshd" },
      { "collector" => "journal", "unit" => "sshd.service", "lines" => 100_000 },
      { "collector" => "file_stat", "path" => "/etc/shadow" },
      { "collector" => "file_stat", "path" => "/proc/1/environ" } ].each do |opts|
      task = build_task(opts)
      expect(task).not_to be_valid, opts.inspect
      expect(task.errors[:options].join).to match(/probe\.node_inspect/)
    end
  end

  it "does not disturb other commands' options" do
    expect(build_task({ "anything" => "goes" }, command: "sync_modules")).to be_valid
  end

  # Guarded on the CHANGE, like operable_type and the restart scope: a row that
  # already exists must stay saveable through its status transitions.
  it "does not re-validate a persisted row's options on an unrelated update" do
    task = build_task({ "collector" => "routes" })
    task.save!
    task.update_columns(options: { "collector" => "ssh", "command" => "id" })

    expect { task.reload.update!(progress: 50) }.not_to raise_error
  end

  it "does validate when the options are changed" do
    task = build_task({ "collector" => "routes" })
    task.save!

    expect { task.update!(options: { "collector" => "routes", "command" => "id" }) }
      .to raise_error(ActiveRecord::RecordInvalid, /probe\.node_inspect/)
  end
end
