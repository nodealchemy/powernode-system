# frozen_string_literal: true

require "rails_helper"

# IMP-dbc22946e05c — step 2 of task log surfacing. The agent keeps only a scrubbed
# tail of a build's output; a failure whose cause scrolled out of that window could
# not be diagnosed over MCP. The full scrubbed log is now uploaded and stored here.
#
# NO SECRETS IN LOGS is a hard requirement, so the text is redacted when it is
# written AND again when a page is read (a redactor that learns a new pattern
# later also covers logs stored before it did), and every cut happens on
# already-redacted text.
RSpec.describe System::TaskLogStore do
  let(:account)  { create(:account) }
  let(:instance) { create(:system_node_instance, account: account) }
  let(:task) do
    System::Task.create!(account: account, command: "ci.module_build", status: "running",
                         operable_type: "System::NodeInstance", operable_id: instance.id)
  end

  let(:fake_bearer)   { "Bearer FAKEFAKEFAKEFAKEFAKEFAKEFAKE0001" }
  let(:fake_password) { "password=FAKEhunter2FAKE" }

  describe ".write!" do
    it "stores the log redacted of credential-shaped tokens" do
      described_class.write!(task: task, text: "step 1\nAuthorization: #{fake_bearer}\nrun #{fake_password}\ndone\n")

      stored = System::TaskLog.find_by!(task_id: task.id).content
      expect(stored).to include("step 1", "done")
      expect(stored).not_to include("FAKEFAKEFAKEFAKE", "FAKEhunter2FAKE")
    end

    it "records who and what: account, instance, byte size, and the agent's own truncation statement" do
      described_class.write!(task: task, text: "abc\n", original_bytes: 9_000_000, truncated: true)

      row = System::TaskLog.find_by!(task_id: task.id)
      expect(row.account_id).to eq(account.id)
      expect(row.node_instance_id).to eq(instance.id)
      expect(row.byte_size).to eq(4)
      expect(row.original_bytes).to eq(9_000_000)
      expect(row.truncated).to be(true)
    end

    it "caps what it stores, keeping the END of the log, and says it truncated" do
      stub_const("#{described_class}::MAX_BYTES", 100)
      text = ("a" * 200) + "THE-FAILING-LINE\n"

      described_class.write!(task: task, text: text)

      row = System::TaskLog.find_by!(task_id: task.id)
      expect(row.byte_size).to be <= 100
      expect(row.content).to end_with("THE-FAILING-LINE\n")
      expect(row.truncated).to be(true)
      expect(row.original_bytes).to eq(text.bytesize)
    end

    it "replaces an earlier upload for the same task rather than adding a second row" do
      described_class.write!(task: task, text: "first")
      described_class.write!(task: task, text: "second")

      expect(System::TaskLog.where(task_id: task.id).count).to eq(1)
      expect(System::TaskLog.find_by!(task_id: task.id).content).to eq("second")
    end

    it "bounds retention: expires_at is set from the retention setting, default 14 days" do
      described_class.write!(task: task, text: "x")

      expires = System::TaskLog.find_by!(task_id: task.id).expires_at
      expect(expires).to be_within(1.minute).of(14.days.from_now)
    end

    it "prunes this instance's expired rows on the way in" do
      old_task = System::Task.create!(account: account, command: "ci.module_build", status: "complete",
                                      operable_type: "System::NodeInstance", operable_id: instance.id)
      described_class.write!(task: old_task, text: "old")
      System::TaskLog.where(task_id: old_task.id).update_all(expires_at: 1.hour.ago)

      described_class.write!(task: task, text: "new")

      expect(System::TaskLog.where(task_id: old_task.id)).to be_empty
      expect(System::TaskLog.where(task_id: task.id)).to exist
    end

    it "prunes expired rows of ANY instance, a bounded batch at a time" do
      other_instance = create(:system_node_instance, account: account)
      old_task = System::Task.create!(account: account, command: "ci.module_build", status: "complete",
                                      operable_type: "System::NodeInstance", operable_id: other_instance.id)
      described_class.write!(task: old_task, text: "old")
      System::TaskLog.where(task_id: old_task.id).update_all(expires_at: 1.hour.ago)

      described_class.write!(task: task, text: "new")

      expect(System::TaskLog.where(task_id: old_task.id)).to be_empty
    end

    it "bounds the input before redacting and states the cut" do
      stub_const("#{described_class}::MAX_BYTES", 100)
      described_class.write!(task: task, text: ("a" * 1000) + "END\n")

      row = System::TaskLog.find_by!(task_id: task.id)
      expect(row.content).to end_with("END\n")
      expect(row.truncated).to be(true)
    end

    it "tolerates invalid UTF-8 from a build tool instead of raising" do
      expect { described_class.write!(task: task, text: "ok \xFF\xFE bytes\n".b) }.not_to raise_error
      expect(System::TaskLog.find_by!(task_id: task.id).content).to include("ok")
    end
  end

  describe ".read_page" do
    let(:text) { (1..50).map { |i| "line #{i}\n" }.join }

    before { described_class.write!(task: task, text: text) }

    it "returns a bounded page with has_more and the next offset, and walks to the end" do
      first = described_class.read_page(task: task, offset: 0, limit: 100)
      expect(first[:content].bytesize).to be <= 100
      expect(first[:has_more]).to be(true)
      expect(first[:next_offset]).to eq(first[:offset] + first[:content].bytesize)
      expect(first[:total_bytes]).to eq(text.bytesize)

      collected = first[:content].dup
      cursor = first
      while cursor[:has_more]
        cursor = described_class.read_page(task: task, offset: cursor[:next_offset], limit: 100)
        collected << cursor[:content]
      end
      expect(collected).to eq(text)
      expect(cursor[:has_more]).to be(false)
    end

    it "clamps the limit to the server maximum and defaults it" do
      stub_const("#{described_class}::MAX_PAGE_BYTES", 64)

      page = described_class.read_page(task: task, offset: 0, limit: 10_000_000)
      expect(page[:content].bytesize).to be <= 64

      default = described_class.read_page(task: task, offset: 0, limit: nil)
      expect(default[:content]).not_to be_empty
    end

    it "redacts AGAIN at read, so a stored row written before a pattern existed cannot leak" do
      System::TaskLog.where(task_id: task.id).update_all(content: "leaked #{fake_password} and #{fake_bearer}\n")

      page = described_class.read_page(task: task, offset: 0, limit: 1000)

      expect(page[:content]).not_to include("FAKEhunter2FAKE", "FAKEFAKEFAKEFAKE")
    end

    it "returns nil when the task has no log, or the log has expired" do
      other = System::Task.create!(account: account, command: "ci.module_build", status: "running",
                                   operable_type: "System::NodeInstance", operable_id: instance.id)
      expect(described_class.read_page(task: other, offset: 0, limit: 10)).to be_nil

      System::TaskLog.where(task_id: task.id).update_all(expires_at: 1.minute.ago)
      expect(described_class.read_page(task: task, offset: 0, limit: 10)).to be_nil
    end

    it "treats a negative or non-numeric offset as 0 and an offset past the end as an empty last page" do
      expect(described_class.read_page(task: task, offset: -5, limit: 10)[:offset]).to eq(0)
      past = described_class.read_page(task: task, offset: 10_000_000, limit: 10)
      expect(past[:content]).to eq("")
      expect(past[:has_more]).to be(false)
    end

    it "carries the truncation statement the upload recorded" do
      described_class.write!(task: task, text: "x", original_bytes: 5_000_000, truncated: true)

      page = described_class.read_page(task: task, offset: 0, limit: 10)
      expect(page[:truncated]).to be(true)
      expect(page[:original_bytes]).to eq(5_000_000)
    end
  end
end
