# frozen_string_literal: true

require "rails_helper"

# TemplateComposerService#dependency_graph — the graph half of the
# compose-preview payload, served by the REST compose_preview and by the
# system_compose_preview_template MCP action (TemplateCompositionAnalysis#
# preview_for), and typed in the operator UI at
# frontend/.../services/api/templatesApi.ts.
#
# It builds edges in TWO layers that must agree on what `source` means:
#
#   Layer 1  parent_module hierarchy. A dependant child (config/instance
#            variety) overrides a subscription-variety base — node_module.rb
#            documents parent_module as "the subscription-variety base whose
#            deployment this child overrides", and the child's `file_spec`
#            delegates to `parent.dependency_spec`. So the CHILD depends on the
#            PARENT.
#   Layer 2  ModuleDependency rows (requires/recommends/conflicts/provides).
#            Here the row's owner is the dependent.
#
# Both land in one flat `edges` array that consumers read uniformly — the TS
# type is `{ source, target, type }[]` with no layer marker — so a consumer
# asking "what does X depend on" by filtering `source == X` must get one
# answer, not two conventions. IMP-fa81fd1939b6.
RSpec.describe System::TemplateComposerService, "#dependency_graph" do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }

  def mod(name, variety: "subscription", parent: nil)
    create(:system_node_module, account: account, node_platform: platform, category: category,
           variety: variety, name: "#{name}-#{SecureRandom.hex(3)}", parent_module: parent)
  end

  def depends(owner, dependency, type: "requires", required: true, constraint: nil)
    ::System::ModuleDependency.create!(node_module: owner, dependency: dependency,
                                       dependency_type: type, required: required,
                                       version_constraint: constraint)
  end

  # Mirrors how TemplateCompositionAnalysis hands modules over: eager-loaded,
  # in resolver order.
  def graph_for(modules, explicit: [])
    described_class.new(reload(modules)).dependency_graph(explicit_ids: explicit.map(&:id).to_set)
  end

  def reload(modules)
    ::System::NodeModule.where(id: modules.map(&:id))
                        .includes(:module_dependencies, :category, :current_version, :node_platform)
                        .sort_by { |m| modules.map(&:id).index(m.id) }
  end

  describe "nodes" do
    it "emits exactly one node per module, flagging the operator's own picks" do
      picked = mod("picked")
      pulled = mod("pulled")

      graph = graph_for([ picked, pulled ], explicit: [ picked ])

      expect(graph[:nodes].map { |n| n[:id] }).to eq([ picked.id, pulled.id ])
      expect(graph[:nodes].find { |n| n[:id] == picked.id })
        .to include(explicit: true, auto_resolved: false, name: picked.name, variety: "subscription")
      expect(graph[:nodes].find { |n| n[:id] == pulled.id })
        .to include(explicit: false, auto_resolved: true)
    end

    # The resolver hands modules over already ordered (priority, then
    # resolution order). Node order is the ONLY place that ordering survives
    # into the payload — there is no priority field on a node — so a consumer
    # showing compose order depends on it being preserved verbatim.
    it "preserves the order the resolver handed over" do
      a = mod("first")
      b = mod("second")
      c = mod("third")

      expect(graph_for([ c, a, b ])[:nodes].map { |n| n[:id] }).to eq([ c.id, a.id, b.id ])
    end
  end

  describe "edge direction (the dependent is always the source)" do
    it "points a dependant CHILD at its parent, not the other way round" do
      parent = mod("base")
      child  = mod("override", variety: "config", parent: parent)

      edges = graph_for([ parent, child ])[:edges]

      expect(edges).to contain_exactly(
        hash_including(source: child.id, target: parent.id, type: "depends_on")
      )
    end

    it "points a module at the dependency its ModuleDependency row names" do
      owner = mod("owner")
      dep   = mod("dep")
      depends(owner, dep)

      edges = graph_for([ owner, dep ])[:edges]

      expect(edges).to contain_exactly(
        hash_including(source: owner.id, target: dep.id, type: "requires")
      )
    end

    # The two layers in one payload: both must answer "what does X depend on"
    # the same way, or a consumer filtering on `source` reads one of them
    # backwards.
    it "uses the same convention for both layers at once" do
      base  = mod("base")
      child = mod("override", variety: "config", parent: base)
      dep   = mod("dep")
      depends(child, dep)

      sources_for_child = graph_for([ base, child, dep ])[:edges]
                          .select { |e| e[:source] == child.id }
                          .map { |e| e[:target] }

      # Everything the child depends on — its parent AND its declared
      # dependency — is reachable from one filter.
      expect(sources_for_child).to contain_exactly(base.id, dep.id)
    end
  end

  describe "edges only within the resolved closure" do
    it "drops a parent edge when the parent is not in the closure" do
      parent = mod("absent-base")
      child  = mod("override", variety: "config", parent: parent)

      expect(graph_for([ child ])[:edges]).to be_empty
    end

    it "drops a dependency edge when the dependency is not in the closure" do
      owner = mod("owner")
      depends(owner, mod("absent-dep"))

      expect(graph_for([ owner ])[:edges]).to be_empty
    end
  end

  describe "edge payload" do
    it "carries the dependency's type, requiredness and version constraint" do
      owner = mod("owner")
      dep   = mod("dep")
      depends(owner, dep, type: "recommends", required: false, constraint: ">= 1.2")

      expect(graph_for([ owner, dep ])[:edges].first).to include(
        type: "recommends", required: false, version_constraint: ">= 1.2"
      )
    end
  end

  describe "shapes that must not hang or duplicate" do
    # Why dependency_graph can emit edges without traversing, and so cannot
    # hang on a cycle: the cycle is refused at the source. ModuleDependency
    # validates no_circular_dependency, so a dependency cycle cannot be
    # persisted for the graph to contain. Pinned here because that guarantee
    # lives in another model — if it were ever relaxed, this method would start
    # handing consumers a cyclic graph and this example is what says so.
    it "cannot be handed a dependency cycle: the model refuses to create one" do
      a = mod("a")
      b = mod("b")
      depends(a, b)

      expect { depends(b, a) }
        .to raise_error(ActiveRecord::RecordInvalid, /circular dependency/)

      expect(graph_for([ a, b ])[:edges])
        .to contain_exactly(hash_including(source: a.id, target: b.id))
    end

    it "emits both edges when a child ALSO declares a dependency on its parent" do
      parent = mod("base")
      child  = mod("override", variety: "config", parent: parent)
      depends(child, parent)

      edges = graph_for([ parent, child ])[:edges]

      # Same pair, two distinct relations — kept apart by `type`, and both
      # pointing the same way now that the layers agree.
      expect(edges.map { |e| e[:type] }).to contain_exactly("depends_on", "requires")
      expect(edges.map { |e| [ e[:source], e[:target] ] }.uniq).to eq([ [ child.id, parent.id ] ])
    end
  end
end
