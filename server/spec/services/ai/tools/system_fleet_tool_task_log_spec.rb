# frozen_string_literal: true

require "rails_helper"

# IMP-dbc22946e05c — system_get_task_log, the one read verb for a task's full
# stored log: a bounded page with has_more. An instance principal may read only
# its OWN instance's tasks; a user principal is account-scoped.
RSpec.describe Ai::Tools::SystemFleetTool, "system_get_task_log" do
  let(:account)  { create(:account) }
  let(:user)     { create(:user, account: account, permissions: %w[system.infra_tasks.read]) }
  let(:instance) { create(:system_node_instance, :running, account: account) }
  let(:other)    { create(:system_node_instance, :running, account: account) }

  def make_task(inst)
    System::Task.create!(account: account, command: "ci.module_build", status: "complete",
                         operable_type: "System::NodeInstance", operable_id: inst.id)
  end

  let(:task) { make_task(instance) }
  let(:text) { (1..40).map { |i| "line #{i}\n" }.join }

  before { System::TaskLogStore.write!(task: task, text: text) }

  def user_tool = described_class.new(account: account, user: user)

  def instance_tool(own)
    described_class.new(account: account, user: nil).tap do |t|
      t.instance_authorized = true
      t.node_instance = own
    end
  end

  def call(tool, **rest) = tool.execute(params: { action: "system_get_task_log", task_id: task.id }.merge(rest))

  it "is declared as a read-only action with a required task_id and paging parameters" do
    definition = described_class.action_definitions.fetch("system_get_task_log")

    expect(definition[:parameters][:task_id][:required]).to be(true)
    expect(definition[:parameters].keys).to include(:offset, :limit)
    expect(described_class::ACTION_PERMISSIONS["system_get_task_log"]).to eq("system.infra_tasks.read")
  end

  it "returns a bounded page with has_more, next_offset and total_bytes" do
    r = call(user_tool, limit: 80)

    expect(r[:success]).to be(true)
    page = r[:data]
    expect(page[:content].bytesize).to be <= 80
    expect(page[:has_more]).to be(true)
    expect(page[:next_offset]).to eq(page[:offset] + page[:content].bytesize)
    expect(page[:total_bytes]).to eq(text.bytesize)
    expect(page[:task_id]).to eq(task.id)
  end

  it "pages to the end and reassembles the whole log" do
    collected = +""
    offset = 0
    loop do
      page = call(user_tool, offset: offset, limit: 90)[:data]
      collected << page[:content]
      break unless page[:has_more]

      offset = page[:next_offset]
    end

    expect(collected).to eq(text)
  end

  it "redacts at read even if the stored row holds a secret" do
    System::TaskLog.where(task_id: task.id).update_all(content: "x password=FAKEhunter2FAKE y\n")

    expect(call(user_tool)[:data][:content]).not_to include("FAKEhunter2FAKE")
  end

  it "says so when the task has no stored log, rather than returning an empty success" do
    bare = make_task(instance)
    r = user_tool.execute(params: { action: "system_get_task_log", task_id: bare.id })

    expect(r[:success]).to be(false)
    expect(r[:error]).to match(/no stored log/i)
  end

  it "does not reveal another account's task" do
    foreign = System::Task.create!(account: create(:account), command: "ci.module_build", status: "complete")

    r = user_tool.execute(params: { action: "system_get_task_log", task_id: foreign.id })

    expect(r[:success]).to be(false)
  end

  describe "instance principal" do
    it "reads its own instance's task log" do
      expect(call(instance_tool(instance))[:success]).to be(true)
    end

    it "is refused another instance's task, with the same answer as a task that does not exist" do
      refused = call(instance_tool(other))
      missing = instance_tool(other).execute(params: { action: "system_get_task_log", task_id: SecureRandom.uuid })

      expect(refused[:success]).to be(false)
      expect(refused[:error]).to eq(missing[:error])
      expect(refused.to_s).not_to include("line 1")
    end

    it "is refused when it carries no node identity of its own" do
      tool = described_class.new(account: account, user: nil).tap { |t| t.instance_authorized = true }

      expect(call(tool)[:success]).to be(false)
    end
  end
end
