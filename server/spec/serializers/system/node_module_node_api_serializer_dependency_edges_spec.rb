# frozen_string_literal: true

require "rails_helper"

# The on-node agent decides whether a generated systemd unit gets a hard
# `Requires=` or a best-effort `Wants=` from each dependency edge's KIND.
# Before IMP-f87b5689aca2 this serializer emitted only `svc.dependencies
# .map(&:name)`, so the kind never left the database and every edge —
# including one the manifest declared `softdep` — rendered on-node as a
# hard requirement.
#
# These examples are stated as an EQUALITY over the emitted edge set, not
# as "a softdep edge is present somewhere": the defect was that all three
# kinds were indistinguishable on the wire, and an existence check that
# only looks for the service NAME passes on the broken serializer.
RSpec.describe System::NodeModuleNodeApiSerializer, type: :serializer do
  let(:account)     { create(:account) }
  let(:node_module) { create(:system_node_module, account: account) }

  def service(name)
    create(:system_module_service, node_module: node_module, account: account, name: name)
  end

  def emitted_services
    described_class.new(node_module.reload).full.dig(:module, :services) ||
      described_class.new(node_module.reload).full[:services]
  end

  def edges_for(name)
    svc = emitted_services.find { |s| s[:name] == name }
    expect(svc).not_to be_nil, "service #{name.inspect} missing from the node payload"
    svc[:dependency_edges]
  end

  describe "#full dependency_edges" do
    it "carries each edge's kind, not just the depended-on service name" do
      bootstrap = service("bootstrap")
      proxy     = service("mcp-proxy")
      System::ModuleServiceDependency.create!(module_service: proxy,
                                              depends_on_module_service: bootstrap,
                                              kind: "start_before")

      expect(edges_for("mcp-proxy")).to eq([ { service: "bootstrap", kind: "start_before" } ])
    end

    it "distinguishes all three kinds rather than flattening them" do
      hard   = service("hard-dep")
      health = service("health-dep")
      soft   = service("soft-dep")
      src    = service("consumer")

      System::ModuleServiceDependency.create!(module_service: src, depends_on_module_service: hard,   kind: "start_before")
      System::ModuleServiceDependency.create!(module_service: src, depends_on_module_service: health, kind: "requires_health")
      System::ModuleServiceDependency.create!(module_service: src, depends_on_module_service: soft,   kind: "softdep")

      expect(edges_for("consumer").sort_by { |e| e[:service] }).to eq([
        { service: "hard-dep",   kind: "start_before" },
        { service: "health-dep", kind: "requires_health" },
        { service: "soft-dep",   kind: "softdep" }
      ])
    end

    it "still emits the legacy names-only dependencies field, so an older agent is unaffected" do
      bootstrap = service("bootstrap")
      proxy     = service("mcp-proxy")
      System::ModuleServiceDependency.create!(module_service: proxy,
                                              depends_on_module_service: bootstrap,
                                              kind: "softdep")

      svc = emitted_services.find { |s| s[:name] == "mcp-proxy" }
      expect(svc[:dependencies]).to eq([ "bootstrap" ])
    end

    it "emits an empty edge list for a service with no dependencies" do
      service("standalone")
      expect(edges_for("standalone")).to eq([])
    end
  end
end
