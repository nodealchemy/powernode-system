# frozen_string_literal: true

require "rails_helper"

# IMP-67aea0728774 — the machine surface for the reuse-first gate the module
# authoring runbook demands: "does a module/template for purpose X already
# exist?". Lives in its own spec file so it does not collide with the concurrent
# edits to system_fleet_tool_spec.rb.
# IMP-a9adf9ea4399 — seed_count rides both discovery payloads but neither
# schema explained it, so an agent reading "seed_count: 30" beside 10 results
# had no way to know it means "more matches exist beyond your top_k" rather
# than something about the page it received.
RSpec.describe "system_discover_* schema documents seed_count" do
  it "explains seed_count in both discovery descriptions" do
    defs = Ai::Tools::SystemFleetTool.action_definitions
    %w[system_discover_modules system_discover_templates].each do |action|
      expect(defs.dig(action, :description)).to match(/seed_count/),
        "#{action} returns seed_count but never says what it means"
    end
  end
end

RSpec.describe Ai::Tools::SystemFleetTool, "catalog discovery" do
  let(:account)  { create(:account) }
  let(:platform_record) { create(:system_node_platform, account: account) }
  let(:tool)     { described_class.new(account: account, internal: true) }
  let(:near_vec) { Array.new(1536, 0.1) }
  let(:far_vec)  { Array.new(1536, -0.1) }

  def call(action, **rest)
    tool.execute(params: { action: action }.merge(rest))
  end

  def embed!(record, vector)
    record.class.where(id: record.id)
          .update_all(embedding: vector, embedding_generated_at: Time.current)
    record
  end

  before do
    allow_any_instance_of(::Ai::Memory::EmbeddingService)
      .to receive(:generate).and_return(near_vec)
  end

  describe "action registration" do
    it "declares both discovery actions with an intent parameter" do
      defs = described_class.action_definitions

      expect(defs).to have_key("system_discover_modules")
      expect(defs).to have_key("system_discover_templates")
      expect(defs["system_discover_modules"][:parameters][:intent][:required]).to be true
      expect(defs["system_discover_templates"][:parameters][:intent][:required]).to be true
    end

    it "gates both actions on catalog read permissions" do
      expect(described_class::ACTION_PERMISSIONS["system_discover_modules"]).to eq("system.modules.read")
      # templates.read, not nodes.read: IMP-767c0448b8b9 moved every template
      # surface onto the templates family (the catalog registers it, and REST
      # gates template reads there). Each discovery action still takes the
      # permission of its list counterpart — the counterpart moved too.
      expect(described_class::ACTION_PERMISSIONS["system_discover_templates"]).to eq("system.templates.read")
    end

    it "is routed to SystemFleetTool by the core registry" do
      expect(::Ai::Tools::PlatformApiToolRegistry::TOOLS["system_discover_modules"])
        .to eq("Ai::Tools::SystemFleetTool")
      expect(::Ai::Tools::PlatformApiToolRegistry::TOOLS["system_discover_templates"])
        .to eq("Ai::Tools::SystemFleetTool")
    end
  end

  describe "system_discover_modules" do
    let!(:near) do
      embed!(create(:system_node_module, account: account, name: "nginx-proxy",
                    description: "reverse proxy"), near_vec)
    end
    let!(:far) do
      embed!(create(:system_node_module, account: account, name: "postgres",
                    description: "database"), far_vec)
    end

    it "returns semantically ranked modules with similarity, reason and confidence" do
      result = call("system_discover_modules", intent: "reverse proxy")

      expect(result[:success]).to be(true)
      first = result[:data][:results].first
      expect(first[:name]).to eq("nginx-proxy")
      expect(first[:module_id]).to eq(near.id)
      expect(first[:similarity]).to be_a(Float)
      expect(first[:reason]).to match(/reverse proxy/i)
      expect(result[:data][:confidence]).to eq("high")
      expect(result[:data][:intent]).to eq("reverse proxy")
    end

    # Counts are baseline-relative — creating an Account seeds a starter module
    # catalog, none of which is embedded until the backfill runs.
    it "surfaces catalog coverage so an empty result is distinguishable from an unindexed catalog" do
      baseline = ::System::NodeModule.where(account: account).enabled.count
      create(:system_node_module, account: account, name: "never-embedded")

      result = call("system_discover_modules", intent: "reverse proxy")

      expect(result[:data][:coverage][:total]).to eq(baseline + 1)
      expect(result[:data][:coverage][:embedded]).to eq(2)
      expect(result[:data][:coverage][:unembedded]).to eq(baseline - 1)
    end

    it "fails clearly when the embedding provider is unavailable (no lexical fallback)" do
      allow_any_instance_of(::Ai::Memory::EmbeddingService).to receive(:generate).and_return(nil)

      result = call("system_discover_modules", intent: "reverse proxy")

      expect(result[:success]).to be(false)
      expect(result[:error]).to match(/embedding/i)
    end

    it "rejects a blank intent" do
      result = call("system_discover_modules", intent: "")

      expect(result[:success]).to be(false)
      expect(result[:error]).to match(/intent/i)
    end

    it "honors the variety filter" do
      embed!(create(:system_node_module, account: account, name: "sub-mod",
                    variety: "subscription"), near_vec)

      result = call("system_discover_modules", intent: "x", variety: "subscription")

      expect(result[:data][:results].map { |r| r[:name] }).to eq([ "sub-mod" ])
    end
  end

  describe "system_discover_templates" do
    let!(:near) do
      embed!(create(:system_node_template, account: account, node_platform: platform_record,
                    name: "web-stack", description: "public web serving"), near_vec)
    end
    let!(:far) do
      embed!(create(:system_node_template, account: account, node_platform: platform_record,
                    name: "batch-stack", description: "nightly batch"), far_vec)
    end

    it "returns semantically ranked templates with their module counts" do
      ::System::TemplateModule.create!(
        node_template: near,
        node_module: create(:system_node_module, account: account, name: "nginx-proxy")
      )

      result = call("system_discover_templates", intent: "web server")

      expect(result[:success]).to be(true)
      first = result[:data][:results].first
      expect(first[:name]).to eq("web-stack")
      expect(first[:template_id]).to eq(near.id)
      expect(first[:module_count]).to eq(1)
      expect(result[:data][:confidence]).to eq("high")
    end

    it "fails clearly when the embedding provider is unavailable" do
      allow_any_instance_of(::Ai::Memory::EmbeddingService).to receive(:generate).and_return(nil)

      result = call("system_discover_templates", intent: "web server")

      expect(result[:success]).to be(false)
      expect(result[:error]).to match(/embedding/i)
    end
  end

  # system_list_templates took NO parameters, so an agent could not narrow the
  # catalog at all — it had to pull every template and filter client-side.
  # Names are prefixed so they don't collide with the templates an Account is
  # seeded with (base, hardened, web-apache, web-nginx, ...).
  describe "system_list_templates filtering" do
    before do
      create(:system_node_template, account: account, node_platform: platform_record,
             name: "acme-frontdoor", description: "public web serving")
      create(:system_node_template, account: account, node_platform: platform_record,
             name: "acme-cruncher", description: "nightly batch runner")
    end

    it "still lists everything with no filter" do
      result = call("system_list_templates")

      expect(result[:success]).to be(true)
      expect(result[:data][:count]).to eq(::System::NodeTemplate.where(account: account).count)
    end

    it "filters on name" do
      result = call("system_list_templates", q: "acme-front")

      expect(result[:data][:templates].map { |t| t[:name] }).to eq([ "acme-frontdoor" ])
    end

    it "filters on description" do
      result = call("system_list_templates", q: "nightly batch")

      expect(result[:data][:templates].map { |t| t[:name] }).to eq([ "acme-cruncher" ])
    end

    it "declares the filter parameter" do
      expect(described_class.action_definitions["system_list_templates"][:parameters]).to have_key(:q)
    end
  end
end
