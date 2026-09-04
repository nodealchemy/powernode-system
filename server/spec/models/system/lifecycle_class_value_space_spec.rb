# frozen_string_literal: true

require "rails_helper"

# IMP-2fc66d5b7e00 — three tables carried a column called `lifecycle_class` and
# the three did NOT share a value space. Two of the three are gone now, and
# this file's job has narrowed with them:
#
#   system_nodes           persistent|ephemeral|spot   RETIRED (IMP-19843220ac68,
#                                                       step 1) and DROPPED
#                                                       (IMP-f2a7a729d39b, step 2)
#   system_instance_pools  ephemeral|spot              NOT NULL, default ephemeral,
#                                                       CHECK — the ONE column left
#   system_node_instances  task_scoped (and NULL)      RENAMED to lease_class
#                                                       (IMP-1e2e7b43b083), no CHECK
#
# Two separate facts lived here, and they had different verdicts.
#
# (1) NODE vs POOL was deliberate LAYERING, load-bearing until IMP-19843220ac68.
#     `InstancePoolService#provision_warming_member!` wrote
#     `lifecycle_class: pool.lifecycle_class` onto the member's Node, so every
#     value a pool may hold had to ALSO be a value a Node may hold, and this
#     file pinned that subset relation by wire value. Step 1 stopped the copy
#     and step 2 dropped the node column, its CHECK and the node model's
#     constant and validation, so the invariant has NO SUBJECT any more. What
#     is left to pin is that the pool is the sole holder: its value space by
#     literal, its CHECK, and that a Node has no such attribute at all — so a
#     revived copy fails with UnknownAttributeError rather than silently
#     nesting again.
#
# (2) NODE_INSTANCE was a DIFFERENT AXIS wearing the same name. `task_scoped`
#     answers "why was this instance leased" (fulfillment reaper provenance),
#     not "how long-lived is this machine". IMP-1e2e7b43b083 resolved that by
#     RENAMING the column to `system_node_instances.lease_class`. This file
#     keeps its third-axis examples because the renamed column must go on
#     being rejected by the surviving sibling; the rename itself is guarded by
#     spec/models/system/node_instance_lease_class_spec.rb.
#
# THE NODE COLUMN WAS A SNAPSHOT, NOT A VIEW — and the reason the retirement
# went the way it did. A pool's `lifecycle_class` is rotatable after members
# exist (GitOps `apply_pool` "update" carries it in POOL_SCALAR_KEYS), and
# rotating it never touched copies written onto member Nodes. The rotation
# example below still drives the REAL arm against a pool with a hand-built
# member, because a propagation added later — onto a revived column, or onto
# anything else on the member — would be just as wrong as the copy was.
#
# WHAT THIS GUARD CAN SEE:
#   - the pool's LIFECYCLE_CLASSES drifting, by literal wire value;
#   - System::Node re-acquiring a LIFECYCLE_CLASSES constant, a lifecycle
#     validation, or the attribute itself by any route (respond_to, exercised
#     against an instance);
#   - a check constraint being widened, narrowed, or added to
#     system_node_instances.lease_class, or one mentioning lifecycle_class
#     coming back on system_nodes;
#   - `task_scoped` becoming acceptable to InstancePool, or landing on a Node;
#   - a pool→node propagation being introduced in the real rotation arm;
#   - the divergence note being stripped from any of the four sites that
#     define the surviving column, decline to copy it, or write the renamed one.
#
# WHAT IT CANNOT SEE:
#   - a PARAPHRASE of the divergence notes: the doc half is a token-level
#     containment check on the contiguous comment run attached to each anchor.
#   - a FIFTH site acquiring a lifecycle_class write. The site list is fixed.
#   - which tables carry the column, by EQUALITY over information_schema —
#     that is node_instance_lease_class_spec.rb's oracle, not duplicated here.
#   - the Go agent or the frontend, neither of which mentions the node column.
#
# Examples tagged `needs_step2_migration` read the live schema; they are
# SKIPPED (spec/support/lifecycle_class_migration_helpers.rb) while 20260904100000
# is absent from schema_migrations, and run for real once it is applied.
#
# SIBLING GUARDS: spec/models/system/node_lifecycle_class_retirement_spec.rb
# pins the drop itself (column, index, CHECK, migration shape, last writer);
# spec/docs/node_lifecycle_class_docs_accuracy_spec.rb pins the pool literal
# by parsing the source file and the operator docs against all of this.

module LifecycleClassValueSpace
  SERVER_ROOT = File.expand_path("../../..", __dir__)

  # Every place that DEFINES the surviving value space, DECLINES to copy it,
  # or WRITES the renamed third column, with the tokens its attached comment
  # run must carry. Each anchor is asserted to occur EXACTLY ONCE first: a
  # duplicated anchor would let an edit land on the wrong copy and still read
  # green.
  SITES = {
    # The place the node column used to be defined, and the place a reader
    # would put it back. The comment run ends at this anchor.
    "app/models/system/node.rb" => {
      anchor: "Guards: spec/models/system/node_lifecycle_class_retirement_spec.rb,",
      tokens: %w[system_instance_pools lease_class IMP-f2a7a729d39b]
    },
    "app/models/system/instance_pool.rb" => {
      anchor: "LIFECYCLE_CLASSES = %w[ephemeral spot].freeze",
      tokens: %w[persistent system_nodes IMP-f2a7a729d39b]
    },
    # This site USED to be the pool->node copy itself
    # (`lifecycle_class: pool.lifecycle_class,`). The anchor is the member-Node
    # constructor it was an argument of — the place a reader would reintroduce
    # it, and the place that records why it must not be.
    "app/services/system/instance_pool_service.rb" => {
      anchor: "node = ::System::Node.create!(",
      tokens: [ "IMP-19843220ac68", "not refreshed", "instance_pool_id" ]
    },
    "app/services/system/fulfillment_advance_orchestrator.rb" => {
      anchor: "attrs[:lease_class]",
      tokens: [ "system_instance_pools", "check constraint", "IMP-1e2e7b43b083" ]
    }
  }.freeze

  # The contiguous run of `#` comment lines ending immediately above `anchor`
  # (the anchor's own trailing comment counts too). Contiguity-bounded rather
  # than windowed: a marker four lines up behind a blank line or a line of code
  # belongs to something else and must not satisfy this site.
  def self.comment_run(text, anchor)
    lines = text.lines.map(&:rstrip)
    idx = lines.index { |line| line.include?(anchor) }
    raise "anchor #{anchor.inspect} not found" if idx.nil?

    run = [ lines[idx] ]
    cursor = idx - 1
    while cursor >= 0 && lines[cursor].lstrip.start_with?("#")
      run.unshift(lines[cursor])
      cursor -= 1
    end
    run.join("\n")
  end

  def self.read(rel)
    path = File.join(SERVER_ROOT, rel)
    raise "expected #{rel} to exist under #{SERVER_ROOT}" unless File.exist?(path)

    File.read(path)
  end
end

RSpec.describe "lifecycle_class value spaces: system_instance_pools is the one column left, system_nodes dropped, system_node_instances renamed" do
  let(:account) { create(:account) }
  let(:node_template) { create(:system_node_template, account: account) }

  def pool!(lifecycle_class:)
    ::System::InstancePool.create!(
      account: account,
      node_template: node_template,
      name: "pool-#{SecureRandom.hex(4)}",
      target_size: 1,
      min_size: 0,
      max_size: 2,
      status: "active",
      lifecycle_class: lifecycle_class
    )
  end

  describe "the value spaces, by wire value" do
    it "System::InstancePool admits exactly ephemeral|spot" do
      expect(::System::InstancePool::LIFECYCLE_CLASSES).to eq(%w[ephemeral spot])
    end

    it "System::Node declares NO value space — the constant and the validation went with the column" do
      expect(::System::Node.const_defined?(:LIFECYCLE_CLASSES, false)).to be(false)
      expect(::System::Node.validators_on(:lifecycle_class)).to be_empty
    end

    it "System::NodeInstance declares NO value space of its own" do
      # The renamed third column is validated by nothing — no constant, no
      # inclusion validation, no CHECK. That is why `task_scoped` can live
      # there, and it is also why it never belonged under the shared name.
      expect(::System::NodeInstance.const_defined?(:LEASE_CLASSES, false)).to be(false)
      expect(::System::NodeInstance.validators_on(:lease_class)).to be_empty
    end
  end

  describe "the database agrees with the models" do
    def lifecycle_check(table)
      ActiveRecord::Base.connection
                        .check_constraints(table)
                        .find { |c| c.expression.to_s.include?("lifecycle_class") }
    end

    it "constrains system_instance_pools to the InstancePool value space, excluding persistent" do
      check = lifecycle_check("system_instance_pools")
      expect(check).not_to be_nil
      ::System::InstancePool::LIFECYCLE_CLASSES.each { |value| expect(check.expression).to include("'#{value}'") }
      expect(check.expression).not_to include("'persistent'")
    end

    it "leaves system_node_instances.lease_class unconstrained" do
      checks = ActiveRecord::Base.connection.check_constraints("system_node_instances")
      expect(checks.select { |c| c.expression.to_s.include?("lease_class") }).to be_empty
      expect(lifecycle_check("system_node_instances")).to be_nil
    end

    it "has no lifecycle_class CHECK on system_nodes any more", :needs_step2_migration do
      expect(lifecycle_check("system_nodes")).to be_nil
    end
  end

  describe "task_scoped belongs to neither lifecycle value space" do
    it "is rejected by System::InstancePool" do
      expect { pool!(lifecycle_class: "task_scoped") }.to raise_error(ActiveRecord::RecordInvalid)
    end

    # There is no Node attribute for the value to land on at all — which is a
    # stronger fact than the inclusion rejection this example used to assert,
    # and the one that makes a revived copy fail loudly.
    it "has no System::Node attribute to land on", :needs_step2_migration do
      expect(::System::Node.new).not_to respond_to(:lifecycle_class)
      expect do
        ::System::Node.new(account: account, node_template: node_template, name: "n", lifecycle_class: "task_scoped")
      end.to raise_error(ActiveModel::UnknownAttributeError)
    end

    it "is accepted by System::NodeInstance — on `lease_class`, not `lifecycle_class`" do
      instance = create(:system_node_instance, account: account)
      instance.update!(lease_class: "task_scoped")
      expect(instance.reload.lease_class).to eq("task_scoped")
      expect(instance).not_to respond_to(:lifecycle_class)
    end
  end

  describe "a pool's class is a value nothing on the member mirrors" do
    let(:gitops_agent) { create(:ai_agent, account: account, slug: "gitops-#{SecureRandom.hex(4)}") }

    # The real rotation arm. REST (`instance_pools_controller` update_params)
    # and MCP (`system_fleet_tool#update_instance_pool`) both refuse
    # lifecycle_class on update, so an approved GitOps pool diff is the ONE
    # post-create path that can rotate a pool's class. Driving it — rather than
    # calling pool.update! — is what makes this example able to see propagation
    # if someone later adds it inside apply_pool: with the node column gone, a
    # propagation onto it raises inside the apply and the result is not ok.
    def gitops_pool_update!(pool, lifecycle_class:)
      proposal = ::Ai::AgentProposal.create!(
        account: account, ai_agent_id: gitops_agent.id,
        title: "GitOps: rotate pool lifecycle_class", proposal_type: "configuration",
        status: "approved", priority: "medium",
        proposed_changes: {
          source: "gitops",
          diff: { kind: "pool", change: "update", resource_id: pool.id,
                  desired: { lifecycle_class: lifecycle_class } }
        }
      )
      ::System::Gitops::ApplyService.apply!(proposal: proposal)
    end

    it "rotates through GitOps apply_pool 'update' and leaves the member carrying only the back-reference", :needs_step2_migration do
      pool = pool!(lifecycle_class: "ephemeral")
      # Hand-built the way provision_warming_member! builds one: no lifecycle
      # attribute, the pool id stamped into config.
      member = ::System::Node.create!(
        account: account,
        node_template: node_template,
        name: "member-#{SecureRandom.hex(4)}",
        enabled: true,
        config: { "instance_pool_id" => pool.id }
      )

      result = gitops_pool_update!(pool, lifecycle_class: "spot")
      expect(result.ok?).to be(true), "GitOps pool update failed: #{result.error.inspect}"

      expect(pool.reload.lifecycle_class).to eq("spot")
      reloaded = member.reload
      expect(reloaded.attributes).not_to have_key("lifecycle_class")
      expect(reloaded.config).to eq({ "instance_pool_id" => pool.id })
    end
  end

  describe "the divergence is documented where each column is defined, declined or written" do
    LifecycleClassValueSpace::SITES.each do |rel, site|
      it "#{rel} carries the note on its lifecycle_class site" do
        text = LifecycleClassValueSpace.read(rel)

        occurrences = text.lines.count { |line| line.include?(site[:anchor]) }
        expect(occurrences).to eq(1),
                               "expected exactly one #{site[:anchor].inspect} in #{rel}, found #{occurrences}"

        run = LifecycleClassValueSpace.comment_run(text, site[:anchor])
        missing = site[:tokens].reject { |token| run.include?(token) }
        expect(missing).to be_empty,
                           "#{rel}: comment run attached to #{site[:anchor].inspect} is missing #{missing.inspect}"
      end
    end
  end
end
