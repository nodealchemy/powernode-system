# frozen_string_literal: true

require "rails_helper"

# IMP-2fc66d5b7e00 — three tables carried a column called `lifecycle_class` and
# the three did NOT share a value space:
#
#   system_nodes           persistent|ephemeral|spot   nullable, NO default, CHECK
#   system_instance_pools  ephemeral|spot              NOT NULL, default ephemeral,  CHECK
#   system_node_instances  task_scoped (and NULL)      nullable, NO check constraint
#
# Two separate facts live here, and they have different verdicts.
#
# (1) NODE vs POOL was deliberate LAYERING, and it was load-bearing until
#     IMP-19843220ac68. `InstancePoolService#provision_warming_member!` wrote
#     `lifecycle_class: pool.lifecycle_class` onto the member's Node, so every
#     value a pool may hold had to ALSO be a value a Node may hold — and
#     nothing enforced it, just two frozen literals in two files that happened
#     to nest. A `persistent` pool is a contradiction (you do not warm and
#     replenish a machine you intend to keep), so the pool set being a STRICT
#     subset is correct; the missing part was the guard. The COPY is now gone
#     (the node column is being retired, step 1: writes stopped, default NULL),
#     but the invariant is still required, because the node CHECK constraint
#     and both constants outlive the write by one deploy window and a revert of
#     the write must not find a narrowed node value space waiting for it.
#
# (2) NODE_INSTANCE was a DIFFERENT AXIS wearing the same name. `task_scoped`
#     answers "why was this instance leased" (fulfillment reaper provenance),
#     not "how long-lived is this machine". It would violate the check
#     constraint on either of the other two tables. That was the collision
#     worth naming, and IMP-1e2e7b43b083 resolved it by RENAMING the column to
#     `system_node_instances.lease_class` — column, partial index, one writer,
#     two readers and the serializer key. This file keeps its third-table
#     examples because they are what makes the node/pool layering legible, and
#     because the renamed column must go on being rejected by both siblings;
#     the rename itself is guarded by
#     spec/models/system/node_instance_lease_class_spec.rb, which must move
#     with this file.
#
# THE NODE COLUMN WAS A SNAPSHOT, NOT A VIEW — pinned below by execution, and
# the reason the retirement decision went the way it did. A pool's
# `lifecycle_class` is rotatable after members exist (GitOps `apply_pool`
# "update" carries it in POOL_SCALAR_KEYS), and rotating it does NOT touch
# copies written onto member Nodes. So the Node column was never an unwired
# intent record waiting for a consumer; where it was non-default it was a
# denormalised duplicate that could already disagree with the row it came from.
# Anything that wants to branch on a machine's lifecycle reads the pool, which
# is authoritative and reachable from a member via config["instance_pool_id"].
# The example below still drives the real rotation arm against a hand-built
# member, because propagation added later would be just as wrong as the copy.
#
# WHAT THIS GUARD CAN SEE:
#   - either model's LIFECYCLE_CLASSES drifting, by literal wire value (a
#     relation-only assertion would stay green if both drifted together);
#   - the layering invariant breaking in either direction — a pool value the
#     Node model or the Node CHECK constraint would reject;
#   - a check constraint being widened, narrowed, or added to
#     system_node_instances.lease_class;
#   - `task_scoped` becoming acceptable to Node or InstancePool;
#   - a pool→node propagation being introduced: the snapshot example drives
#     the REAL rotation arm, System::Gitops::ApplyService#apply_pool "update",
#     so propagation added either there or as an InstancePool callback reddens
#     it. (The create-time COPY it originally guarded is gone; that the member
#     constructor no longer writes the column at all is pinned by
#     spec/models/system/node_lifecycle_class_retirement_spec.rb.);
#   - the divergence note being stripped from any of the four sites that
#     define or write one of these columns.
#
# WHAT IT CANNOT SEE:
#   - a PARAPHRASE of the divergence notes. The doc half is a token-level
#     containment check on the contiguous comment run attached to each anchor;
#     re-worded prose carrying the same tokens passes, and correct prose using
#     different tokens fails loudly rather than silently.
#   - a FIFTH site acquiring a lifecycle_class write. The site list is fixed
#     here; a new writer under server/app is invisible to it.
#   - anything about the Go agent or the frontend, neither of which mentions
#     the column at all.
#   - the member Node being created the way production creates it. The snapshot
#     example hand-builds a member carrying an explicit value, because
#     `InstancePoolService#provision_warming_member!` synchronously provisions a
#     cloud VM — and, since IMP-19843220ac68, no longer writes the column at
#     all. What that method does write is pinned by parsing the call, in
#     spec/models/system/node_lifecycle_class_retirement_spec.rb.
#
# SIBLING GUARD: spec/docs/node_lifecycle_class_docs_accuracy_spec.rb pins the
# SAME two LIFECYCLE_CLASSES literals by parsing the source files. Both files
# must move together when a value space legitimately changes.

module LifecycleClassValueSpace
  SERVER_ROOT = File.expand_path("../../..", __dir__)

  # Every place that DEFINES a lifecycle_class value space or WRITES one of the
  # three columns, with the tokens its attached comment run must carry. Each
  # anchor is asserted to occur EXACTLY ONCE first: a duplicated anchor would
  # let an edit land on the wrong copy and still read green.
  SITES = {
    "app/models/system/node.rb" => {
      anchor: "LIFECYCLE_CLASSES = %w[persistent ephemeral spot].freeze",
      tokens: %w[system_instance_pools system_node_instances task_scoped]
    },
    "app/models/system/instance_pool.rb" => {
      anchor: "LIFECYCLE_CLASSES = %w[ephemeral spot].freeze",
      tokens: [ "system_nodes", "persistent", "System::Node::LIFECYCLE_CLASSES" ]
    },
    # This site USED to be the pool->node copy itself
    # (`lifecycle_class: pool.lifecycle_class,`). IMP-19843220ac68 retired the
    # copy, so the anchor moved to the member-Node constructor it was an
    # argument of — the place a reader would reintroduce it, and the place that
    # now records why it must not be.
    "app/services/system/instance_pool_service.rb" => {
      anchor: "node = ::System::Node.create!(",
      tokens: [ "System::Node::LIFECYCLE_CLASSES", "not refreshed", "IMP-19843220ac68" ]
    },
    "app/services/system/fulfillment_advance_orchestrator.rb" => {
      anchor: "attrs[:lease_class]",
      tokens: [ "system_nodes", "system_instance_pools", "check constraint" ]
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

RSpec.describe "lifecycle_class value spaces across system_nodes / system_instance_pools / system_node_instances" do
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

  describe "the three value spaces, by wire value" do
    it "System::Node admits exactly persistent|ephemeral|spot" do
      expect(::System::Node::LIFECYCLE_CLASSES).to eq(%w[persistent ephemeral spot])
    end

    it "System::InstancePool admits exactly ephemeral|spot" do
      expect(::System::InstancePool::LIFECYCLE_CLASSES).to eq(%w[ephemeral spot])
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

    it "constrains system_nodes to the Node value space" do
      check = lifecycle_check("system_nodes")
      expect(check).not_to be_nil
      ::System::Node::LIFECYCLE_CLASSES.each { |value| expect(check.expression).to include("'#{value}'") }
      expect(check.expression).not_to include("'task_scoped'")
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
  end

  # The invariant provision_warming_member! USED to depend on. It outlives the
  # copy: the node CHECK constraint and both constants survive step 1 of the
  # retirement, so a narrowed node value space would be a landmine for any
  # revert, and for the explicit writes specs and seeds still make.
  describe "the node/pool layering invariant the retired member copy depended on" do
    it "keeps the pool value space a STRICT subset of the node value space" do
      pool_set = ::System::InstancePool::LIFECYCLE_CLASSES
      node_set = ::System::Node::LIFECYCLE_CLASSES

      expect(node_set).to include(*pool_set)
      expect(node_set - pool_set).to eq(%w[persistent])
    end

    it "lets a Node be persisted with EVERY value a pool may hold" do
      # The relation above is a constant comparison; this is the behaviour it
      # stands for — model validation AND the DB check constraint, exercised
      # with the value provision_warming_member! would actually copy.
      ::System::InstancePool::LIFECYCLE_CLASSES.each do |value|
        node = ::System::Node.create!(
          account: account,
          node_template: node_template,
          name: "node-#{value}-#{SecureRandom.hex(4)}",
          enabled: true,
          config: {},
          lifecycle_class: value
        )
        expect(node.reload.lifecycle_class).to eq(value)
      end
    end
  end

  describe "task_scoped belongs to neither of the other two spaces" do
    it "is rejected by System::Node" do
      node = ::System::Node.new(
        account: account, node_template: node_template,
        name: "n-#{SecureRandom.hex(4)}", lifecycle_class: "task_scoped"
      )
      expect(node).not_to be_valid
      expect(node.errors[:lifecycle_class]).to be_present
    end

    it "is rejected by System::InstancePool" do
      expect { pool!(lifecycle_class: "task_scoped") }.to raise_error(ActiveRecord::RecordInvalid)
    end

    it "is accepted by System::NodeInstance — on `lease_class`, not `lifecycle_class`" do
      instance = create(:system_node_instance, account: account)
      instance.update!(lease_class: "task_scoped")
      expect(instance.reload.lease_class).to eq("task_scoped")
      expect(instance).not_to respond_to(:lifecycle_class)
    end
  end

  describe "a node value never follows the pool it was copied from" do
    let(:gitops_agent) { create(:ai_agent, account: account, slug: "gitops-#{SecureRandom.hex(4)}") }

    # The real rotation arm. REST (`instance_pools_controller` update_params)
    # and MCP (`system_fleet_tool#update_instance_pool`) both refuse
    # lifecycle_class on update, so an approved GitOps pool diff is the ONE
    # post-create path that can rotate a pool's class. Driving it — rather than
    # calling pool.update! — is what makes this example able to see propagation
    # if someone later adds it inside apply_pool. Production no longer creates
    # such a copy at all; this pins that reviving the copy by the back door
    # would be no better than the front one.
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

    it "does not follow the pool when GitOps rotates the pool's lifecycle_class" do
      pool = pool!(lifecycle_class: "ephemeral")
      # Hand-built with an explicit value — provision_warming_member! no longer
      # writes one; see the WHAT IT CANNOT SEE note above.
      member = ::System::Node.create!(
        account: account,
        node_template: node_template,
        name: "member-#{SecureRandom.hex(4)}",
        enabled: true,
        lifecycle_class: pool.lifecycle_class,
        config: { "instance_pool_id" => pool.id }
      )

      result = gitops_pool_update!(pool, lifecycle_class: "spot")
      expect(result.ok?).to be(true), "GitOps pool update failed: #{result.error.inspect}"

      expect(pool.reload.lifecycle_class).to eq("spot")
      expect(member.reload.lifecycle_class).to eq("ephemeral")
    end
  end

  describe "the divergence is documented where each column is defined or written" do
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
