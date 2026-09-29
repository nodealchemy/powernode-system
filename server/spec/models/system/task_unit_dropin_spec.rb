# frozen_string_literal: true

require "rails_helper"

# IMP-9951cbf20bb0 — unit.dropin writes a systemd drop-in as root on the node,
# and System::Task#options is free-form JSONB that TasksController#create
# accepts from any holder of system.infra_tasks.create. The verb's controls
# (a person's own-session approval, the unit fence) live in
# System::UnitDropinService, so the model refuses a unit.dropin row that
# service did not mint, and re-checks its options whoever minted it.
RSpec.describe System::Task, "unit.dropin" do
  let(:account)  { create(:account) }
  let(:instance) { create(:system_node_instance, :running, account: account) }
  let(:unit)     { "powernode-019f7cb5-3858-7caa-aa9f-51629dc8e573-sidekiq.service" }
  let(:options) do
    { "unit" => unit, "name" => "trial", "revert" => false,
      "directives" => [ { "key" => "MemoryMax", "value" => "1G" } ] }
  end

  def build_task(opts = options, governed: true)
    described_class.new(account: account, operable: instance, command: "unit.dropin", status: "pending",
                        options: opts).tap { |t| t.governed_unit_dropin = governed }
  end

  it "is a command the platform can mint" do
    expect(described_class::COMMANDS).to include("unit.dropin")
  end

  it "accepts the service's own row" do
    expect(build_task).to be_valid
    expect(build_task(options.merge("revert" => true, "directives" => []))).to be_valid
  end

  it "refuses a row any other producer mints, however well-formed" do
    task = build_task(governed: false)
    expect(task).not_to be_valid
    expect(task.errors[:command].join).to match(/system_apply_unit_dropin/)
  end

  it "refuses options the agent would refuse, even on the service's row" do
    [
      options.merge("name" => "../x"),
      options.merge("unit" => "sshd.service"),
      options.merge("directives" => [ { "key" => "ExecStart", "value" => "/bin/sh" } ]),
      options.merge("directives" => [ { "key" => "MemoryMax", "value" => "1G\nExecStart=/bin/sh" } ]),
      options.merge("directives" => []),
      options.merge("revert" => true),
      options.merge("revert" => "yes"),
      options.merge("extra" => "x"),
      options.except("name")
    ].each do |opts|
      expect(build_task(opts)).not_to be_valid, opts.inspect
    end
  end

  it "keeps an existing row saveable through its status transitions" do
    task = build_task
    task.save!
    reloaded = described_class.find(task.id)

    expect(reloaded.governed_unit_dropin).to be_nil
    expect { reloaded.update!(status: "running") }.not_to raise_error
  end
end
