# frozen_string_literal: true

require "rails_helper"

# IMP-f2a7a729d39b — RETIREMENT of `system_nodes.lifecycle_class`, step 2 of
# two. Step 1 (IMP-19843220ac68, migration 20260902160000) stopped both
# application writers and made the column nullable with a NULL default, and
# this file's previous shape guarded THAT state — column present, default
# gone, nil on create. Step 1 has since been live on ops-hub across two
# deploys, which is the one-release window it bought, so step 2 drops
# everything step 1 deliberately left behind: the column, its
# chk_system_nodes_lifecycle_class CHECK constraint, its index,
# System::Node::LIFECYCLE_CLASSES and the inclusion validation — and the one
# writer step 1 put out of scope, the example_multi_tenant dev seed.
#
# WHAT THIS GUARD CAN SEE:
#   - any of the three schema objects coming back, read from the LIVE
#     connection (schema.rb is core-only and lags extension columns);
#   - the attribute coming back on the model by any route — a real column, an
#     `attribute` declaration, an `attr_accessor` — because both the
#     UnknownAttributeError example and the respond_to example are exercised
#     against the class, not against a column list;
#   - the constant or the validation being re-declared;
#   - the seed helper re-acquiring the keyword, and the seed file re-acquiring
#     the token anywhere (the docs-accuracy spec's seed scan is file-level and
#     would also redden, but that scan skips InstancePool argument blocks and a
#     token in a comment would slip past it here);
#   - the step-2 migration losing its explicit `down`, or `down` restoring the
#     BASELINE (NOT NULL, default persistent) instead of step 1's end state —
#     the shape a module rollback to the step-1 release actually needs;
#   - the pool→member back-reference disappearing, which is what keeps
#     pool.lifecycle_class reachable from a member now that no copy exists.
#
# WHAT IT CANNOT SEE — and deliberately does not duplicate:
#   - THE WRITER ENUMERATION under server/app. That paren-balanced scan is
#     owned by spec/docs/node_lifecycle_class_docs_accuracy_spec.rb; repeating
#     it here would make one regression redden two files. After step 2 a
#     writer would fail at runtime anyway (UnknownAttributeError), which the
#     example below pins directly.
#   - the pool value space. spec/models/system/lifecycle_class_value_space_spec.rb
#     pins System::InstancePool::LIFECYCLE_CLASSES by wire value and the pool
#     CHECK constraint; this file only asserts the pool still HOLDS a value.
#   - a rollback actually being exercised: `down` is pinned by shape, not run.
#
# Examples tagged `needs_step2_migration` read the live schema; they are
# SKIPPED (spec/support/lifecycle_class_migration_helpers.rb) while 20260904100000
# is absent from schema_migrations, and run for real once it is applied — keyed
# on the migration and not on the column, so a column that comes back fails
# here rather than skipping. Every other example is green on the source alone.
RSpec.describe "System::Node lifecycle_class retirement (step 2: column, CHECK, index, constant and validation dropped)" do
  ext_root = File.expand_path("../../../..", __dir__)

  # Paren-balanced over the constructor's ARGUMENT LIST, as in the sibling
  # specs: file-level co-occurrence of `System::Node.create!` and a token is
  # not evidence the constructor sets it.
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

  describe "the model" do
    it "declares no LIFECYCLE_CLASSES constant" do
      expect(::System::Node.const_defined?(:LIFECYCLE_CLASSES, false)).to be(false)
    end

    it "validates nothing on lifecycle_class" do
      expect(::System::Node.validators_on(:lifecycle_class)).to be_empty
    end
  end

  describe "the database", :needs_step2_migration do
    let(:connection) { ActiveRecord::Base.connection }

    it "has no lifecycle_class column on system_nodes" do
      expect(connection.columns("system_nodes").map(&:name)).not_to include("lifecycle_class")
      expect(::System::Node.column_names).not_to include("lifecycle_class")
    end

    it "has no index_system_nodes_on_lifecycle_class" do
      expect(connection.indexes("system_nodes").map(&:name)).not_to include("index_system_nodes_on_lifecycle_class")
    end

    it "has no chk_system_nodes_lifecycle_class, nor any CHECK mentioning the column" do
      checks = connection.check_constraints("system_nodes")
      expect(checks.map(&:name)).not_to include("chk_system_nodes_lifecycle_class")
      expect(checks.select { |c| c.expression.to_s.include?("lifecycle_class") }).to be_empty
    end

    # The behaviour the schema assertions stand for. A Node created the way
    # every remaining caller creates one persists without the attribute, and
    # supplying the attribute by name is an error rather than a silent no-op —
    # which is what makes a reintroduced writer fail loudly instead of writing
    # to nothing.
    it "persists a Node without the attribute and rejects the attribute by name" do
      node = ::System::Node.create!(
        account: account,
        node_template: node_template,
        name: "post-retirement-#{SecureRandom.hex(4)}",
        enabled: true,
        config: {}
      )
      expect(node.reload.attributes).not_to have_key("lifecycle_class")
      expect(node).not_to respond_to(:lifecycle_class)

      expect do
        ::System::Node.new(
          account: account, node_template: node_template,
          name: "revived-#{SecureRandom.hex(4)}", lifecycle_class: "persistent"
        )
      end.to raise_error(ActiveModel::UnknownAttributeError)
    end
  end

  describe "the migration" do
    let(:file) do
      Dir[File.join(ext_root, "server/db/migrate", "*_drop_lifecycle_class_from_system_nodes.rb")].first
    end

    it "exists, drops all three objects in `up`, and restores step 1's end state in `down`" do
      expect(file).not_to be_nil, "the step-2 migration is missing from db/migrate"
      src = File.read(file)

      up = src[/^\s*def up\n(.*?)^\s*end\n/m, 1]
      down = src[/^\s*def down\n(.*?)^\s*end\n/m, 1]
      expect(up).not_to be_nil, "explicit `def up` not found — a `change` cannot express this down"
      expect(down).not_to be_nil, "explicit `def down` not found — the drop must be reversible"

      expect(up).to include('remove_index :system_nodes, name: "index_system_nodes_on_lifecycle_class"')
      expect(up).to include('remove_check_constraint :system_nodes, name: "chk_system_nodes_lifecycle_class"')
      expect(up).to include("remove_column :system_nodes, :lifecycle_class")

      # Step 1's end state — nullable, no default — NOT the baseline. The
      # step-1 release's model validates with allow_nil, so this is the shape
      # a rollback to it needs; restoring NOT NULL here would fail on the
      # first row anyway, since the values are gone with the column.
      expect(down).to include("add_column :system_nodes, :lifecycle_class, :string")
      expect(down).not_to include("null: false")
      expect(down).not_to include("default:")
      expect(down).to include('name: "chk_system_nodes_lifecycle_class"')
      expect(down).to include('name: "index_system_nodes_on_lifecycle_class"')
      expect(down).not_to include("execute(")
    end
  end

  describe "the last writer" do
    # Step 1 put db/seeds/example_multi_tenant.rb out of scope on purpose (a
    # dev seed, not an operator path, "swept by the column DROP"). This is the
    # sweep. Token-level over the whole file, not just the helper signature,
    # so the keyword cannot survive in a call site or a comment.
    it "no longer exists in the example_multi_tenant seed" do
      seed = self.class.read(ext_root, "server/db/seeds/example_multi_tenant.rb")
      expect(seed).to include("def ensure_node!(account:, name:, node_template:)")
      expect(seed).not_to include("lifecycle_class")
    end
  end

  describe "the authoritative value stays reachable from a member" do
    it "still stamps instance_pool_id into the member Node's config" do
      args = self.class.node_create_arguments(
        self.class.read(ext_root, "server/app/services/system/instance_pool_service.rb")
      )
      member = args.find { |a| a.include?("instance_pool_id") }
      expect(member).not_to be_nil,
                            "provision_warming_member! no longer records the pool on the member; " \
                            "pool.lifecycle_class is then unreachable from the Node"
      expect(member).to include('"instance_pool_id" => pool.id')
      expect(member).not_to include("lifecycle_class")
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
