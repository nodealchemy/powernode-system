# frozen_string_literal: true

require "rails_helper"

# IMP-19843220ac68 — RETIREMENT, step 1 of two.
#
# `system_nodes.lifecycle_class` was written by two application paths and read
# by NOTHING (no serializer, no MCP/REST parameter, no GitOps kind, no Go agent
# symbol, no frontend reference). The operator decision at approval was to
# RETIRE it rather than wire it: the pool is the authoritative holder, and no
# surface ever let anybody express intent through the Node column.
#
# WHY THE TWO HALVES MUST LAND TOGETHER, and why this file exists rather than a
# bare "delete the writes" diff. The column was NOT NULL DEFAULT 'persistent'.
# Stopping the writers ALONE would have been actively wrong, not merely inert:
# every pool member — which is by construction `ephemeral` or `spot`, since
# `System::InstancePool` is CHECK-constrained to those two — would have silently
# fallen back to `persistent`, turning an unread column into a WRONG one and
# handing the eventual short-circuit a plausible, confidently-stated lie. So the
# default becomes NULL and the column nullable in the SAME change that stops the
# writes, and "unset" becomes representable.
#
# WHAT THIS GUARD CAN SEE:
#   - the default or the NOT NULL coming back (schema read from the live
#     connection, not from schema.rb, so a hand-edited schema file cannot
#     satisfy it);
#   - a Node created without the attribute acquiring a value again — the
#     BEHAVIOUR the schema assertion stands for, exercised through create!;
#   - the model validation rejecting nil again (which would make every
#     unattributed create! raise);
#   - the pool→member back-reference disappearing. That reference is what makes
#     the retirement safe: `pool.lifecycle_class` stays reachable FROM a member
#     because provision_warming_member! stamps `instance_pool_id` into the
#     member's config, so a future short-circuit can read the authoritative row
#     instead of a stale copy.
#
# WHAT IT CANNOT SEE — and what it deliberately does NOT duplicate:
#   - THE WRITER ENUMERATION ITSELF. Scanning server/app for a
#     `System::Node.create!` that sets the column lives in ONE place,
#     spec/docs/node_lifecycle_class_docs_accuracy_spec.rb, which owned it
#     before this change (it asserted "exactly two writers"; it now asserts
#     none, names the orchestrator individually, and carries the surviving
#     seed writer's own example). Running the same paren-balanced scan here would
#     make reintroducing either write redden two files, which is precisely the
#     shape that stops a reviewer mutating one guard from learning which guard
#     is load-bearing. This file asserts what is NEW instead: the column state,
#     the behaviour, and the back-reference.
#   - a writer that does not go through `System::Node.create!` —
#     `assign_attributes`, `update!`, mass assignment. One such writer exists,
#     `db/seeds/example_multi_tenant.rb`, and it is deliberately OUT of scope
#     here: it writes the literal "persistent" to a dev-seed Node, is not an
#     operator path, and is swept by the column DROP (step 2) along with the
#     CHECK constraint and the index. Its shape is pinned by
#     spec/docs/node_lifecycle_class_docs_accuracy_spec.rb.
#   - a writer under server/lib/ or db/migrate/ (a backfill), neither of which
#     the glob covers.
#   - anything about step 2. The column, its CHECK constraint, its index and
#     `System::Node::LIFECYCLE_CLASSES` all still exist on purpose: dropping
#     them in the same deploy as the write-stop would leave a window in which
#     running code writes a column the migration has removed.
RSpec.describe "System::Node lifecycle_class retirement (writes stopped, default NULL)" do
  ext_root = File.expand_path("../../../..", __dir__)

  # Paren-balanced over the constructor's ARGUMENT LIST. A file-level
  # co-occurrence test is not evidence: system_fleet_tool.rb contains a
  # `System::Node.create!` and a `lifecycle_class:` in two different methods
  # that have nothing to do with each other.
  def self.node_create_arguments(src)
    src.enum_for(:scan, /System::Node\.create!\(/).map { Regexp.last_match.end(0) }.map do |start|
      depth = 1
      i = start
      i += 1 while i < src.length && (depth += (src[i] == "(" ? 1 : src[i] == ")" ? -1 : 0)) > 0
      src[start...i]
    end
  end

  def self.read(ext_root, rel)
    path = File.join(ext_root, rel)
    raise "expected #{rel} to exist under #{ext_root}" unless File.exist?(path)

    File.read(path)
  end

  let(:account) { create(:account) }
  let(:node_template) { create(:system_node_template, account: account) }

  describe "the column no longer manufactures a value" do
    let(:column) do
      ActiveRecord::Base.connection.columns("system_nodes").find { |c| c.name == "lifecycle_class" }
    end

    it "still exists — step 2 drops it, this change must not" do
      expect(column).not_to be_nil
    end

    it "is nullable with a NULL default" do
      expect(column.default).to be_nil
      expect(column.null).to be(true)
    end

    # The behaviour the schema assertion stands for. A default can also be
    # reintroduced in Ruby (an `after_initialize`, an attribute default), which
    # the column read above would not see.
    it "leaves lifecycle_class nil on a Node created without it" do
      node = ::System::Node.create!(
        account: account,
        node_template: node_template,
        name: "unattributed-#{SecureRandom.hex(4)}",
        enabled: true,
        config: {}
      )

      expect(node.lifecycle_class).to be_nil
      expect(node.reload.lifecycle_class).to be_nil
    end

    # The CHECK constraint survives step 1 and must tolerate NULL; a
    # three-valued CHECK does, but only while it is not rewritten with a
    # COALESCE or an IS NOT NULL arm.
    it "still rejects a value outside the declared space, and still accepts each declared one" do
      invalid = ::System::Node.new(
        account: account, node_template: node_template,
        name: "bad-#{SecureRandom.hex(4)}", lifecycle_class: "task_scoped"
      )
      expect(invalid).not_to be_valid
      expect(invalid.errors[:lifecycle_class]).to be_present

      ::System::Node::LIFECYCLE_CLASSES.each do |value|
        node = ::System::Node.create!(
          account: account, node_template: node_template,
          name: "explicit-#{value}-#{SecureRandom.hex(4)}", enabled: true,
          config: {}, lifecycle_class: value
        )
        expect(node.reload.lifecycle_class).to eq(value)
      end
    end
  end

  # NO WRITER-ENUMERATION EXAMPLES HERE, on purpose. That scan is owned by
  # spec/docs/node_lifecycle_class_docs_accuracy_spec.rb — "has no System::Node
  # writer of the column left in server/app", plus the orchestrator named
  # individually and the surviving seed writer. See the header for why it is
  # not repeated in this file.
  describe "the authoritative value stays reachable from a member" do
    # Retiring the copy is only safe because the ORIGINAL is still findable.
    # provision_warming_member! stamps the pool id into the member's config, so
    # a future short-circuit reads pool.lifecycle_class — the row GitOps
    # apply_pool "update" can rotate — instead of a snapshot that was already
    # allowed to go stale.
    it "still stamps instance_pool_id into the member Node's config" do
      args = self.class.node_create_arguments(
        self.class.read(ext_root, "server/app/services/system/instance_pool_service.rb")
      )
      member = args.find { |a| a.include?("instance_pool_id") }
      expect(member).not_to be_nil,
                            "provision_warming_member! no longer records the pool on the member; " \
                            "pool.lifecycle_class is then unreachable from the Node"
      expect(member).to include('"instance_pool_id" => pool.id')
    end

    it "keeps InstancePool as the holder of a real, constrained value" do
      expect(::System::InstancePool::LIFECYCLE_CLASSES).to eq(%w[ephemeral spot])
      pool = ::System::InstancePool.create!(
        account: account, node_template: node_template,
        name: "pool-#{SecureRandom.hex(4)}",
        target_size: 1, min_size: 0, max_size: 2,
        status: "active", lifecycle_class: "spot"
      )
      expect(pool.reload.lifecycle_class).to eq("spot")
    end
  end
end
