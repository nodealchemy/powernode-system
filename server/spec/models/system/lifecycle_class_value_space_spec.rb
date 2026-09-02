# frozen_string_literal: true

require "rails_helper"

# IMP-2fc66d5b7e00 — three tables carry a column called `lifecycle_class` and
# the three do NOT share a value space:
#
#   system_nodes           persistent|ephemeral|spot   NOT NULL, default persistent, CHECK
#   system_instance_pools  ephemeral|spot              NOT NULL, default ephemeral,  CHECK
#   system_node_instances  task_scoped (and NULL)      nullable, NO check constraint
#
# Two separate facts live here, and they have different verdicts.
#
# (1) NODE vs POOL is deliberate LAYERING, and it is load-bearing.
#     `InstancePoolService#provision_warming_member!` writes
#     `lifecycle_class: pool.lifecycle_class` onto the member's Node, so every
#     value a pool may hold must ALSO be a value a Node may hold. That holds
#     today, but nothing enforced it — two frozen literals in two files that
#     happen to nest. A `persistent` pool is a contradiction (you do not warm
#     and replenish a machine you intend to keep), so the pool set being a
#     STRICT subset is correct; the missing part was the guard.
#
# (2) NODE_INSTANCE is a DIFFERENT AXIS wearing the same name. `task_scoped`
#     answers "why was this instance leased" (fulfillment reaper provenance),
#     not "how long-lived is this machine". It would violate the check
#     constraint on either of the other two tables. That is the collision worth
#     naming: reading `lifecycle_class` in a diff tells you nothing about which
#     value set applies until you know which table you are looking at.
#
# THE NODE COLUMN IS A SNAPSHOT, NOT A VIEW — pinned below by execution. A
# pool's `lifecycle_class` is rotatable after members exist (GitOps
# `apply_pool` "update" carries it in POOL_SCALAR_KEYS), and rotating it does
# NOT touch the copies already written onto member Nodes. So the Node column is
# not an unwired intent record waiting for a consumer; where it is non-default
# it is a denormalised duplicate that can already disagree with the row it was
# copied from. Anything that ever wants to branch on a machine's lifecycle
# should read the pool, which is authoritative.
#
# WHAT THIS GUARD CAN SEE:
#   - either model's LIFECYCLE_CLASSES drifting, by literal wire value (a
#     relation-only assertion would stay green if both drifted together);
#   - the layering invariant breaking in either direction — a pool value the
#     Node model or the Node CHECK constraint would reject;
#   - a check constraint being widened, narrowed, or added to
#     system_node_instances;
#   - `task_scoped` becoming acceptable to Node or InstancePool;
#   - the pool→node copy silently becoming live: the snapshot example drives
#     the REAL rotation arm, System::Gitops::ApplyService#apply_pool "update",
#     so propagation added either there or as an InstancePool callback reddens
#     it;
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
#     example hand-builds the member with the attributes
#     `InstancePoolService#provision_warming_member!` writes, because that
#     method synchronously provisions a cloud VM. The attributes it writes are
#     pinned separately, by parsing the call, in
#     spec/docs/node_lifecycle_class_docs_accuracy_spec.rb:294-296.
#
# SIBLING GUARD: spec/docs/node_lifecycle_class_docs_accuracy_spec.rb:299-303
# pins the SAME two LIFECYCLE_CLASSES literals by parsing the source files.
# Both files must move together when a value space legitimately changes.

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
    "app/services/system/instance_pool_service.rb" => {
      anchor: "lifecycle_class: pool.lifecycle_class,",
      tokens: [ "System::Node::LIFECYCLE_CLASSES", "not refreshed" ]
    },
    "app/services/system/fulfillment_advance_orchestrator.rb" => {
      anchor: 'attrs[:lifecycle_class]  = "task_scoped"',
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
      # The third column is validated by nothing — no constant, no inclusion
      # validation, no CHECK. That is why `task_scoped` can live there.
      expect(::System::NodeInstance.const_defined?(:LIFECYCLE_CLASSES, false)).to be(false)
      expect(::System::NodeInstance.validators_on(:lifecycle_class)).to be_empty
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

    it "leaves system_node_instances unconstrained" do
      expect(lifecycle_check("system_node_instances")).to be_nil
    end
  end

  describe "the node/pool layering invariant that provision_warming_member! depends on" do
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

    it "is accepted by System::NodeInstance" do
      instance = create(:system_node_instance, account: account)
      instance.update!(lifecycle_class: "task_scoped")
      expect(instance.reload.lifecycle_class).to eq("task_scoped")
    end
  end

  describe "the node copy is a snapshot of the pool value, not a view of it" do
    let(:gitops_agent) { create(:ai_agent, account: account, slug: "gitops-#{SecureRandom.hex(4)}") }

    # The real rotation arm. REST (`instance_pools_controller` update_params)
    # and MCP (`system_fleet_tool#update_instance_pool`) both refuse
    # lifecycle_class on update, so an approved GitOps pool diff is the ONE
    # post-create path that can rotate a pool's class. Driving it — rather than
    # calling pool.update! — is what makes this example able to see propagation
    # if someone later adds it inside apply_pool.
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
      # Built with the attributes provision_warming_member! writes; see the
      # WHAT IT CANNOT SEE note above for why it is not driven through it.
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
