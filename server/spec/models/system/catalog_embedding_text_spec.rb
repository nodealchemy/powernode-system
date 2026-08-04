# frozen_string_literal: true

require "rails_helper"

# IMP-67aea0728774 — NodeModule / NodeTemplate carry persisted embeddings so
# "does a module for purpose X already exist?" is answerable by machine.
# The embedding_text composition is the single source of truth for what gets
# embedded — a re-embed campaign must produce byte-identical input, so these
# specs pin the composition itself, not just its presence.
RSpec.describe "System catalog embedding text" do
  let(:account)  { create(:account) }
  let(:platform_record) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account, name: "Web Tier") }

  describe System::NodeModule do
    subject(:node_module) do
      create(:system_node_module,
             account: account,
             node_platform: platform_record,
             category: category,
             name: "nginx-proxy",
             variety: "subscription",
             description: "Reverse proxy fronting the application tier",
             capabilities: %w[http-server tls-terminator])
    end

    it "composes name, variety, description, capabilities and category" do
      text = node_module.embedding_text

      expect(text).to include("nginx-proxy")
      expect(text).to include("subscription")
      expect(text).to include("Reverse proxy fronting the application tier")
      expect(text).to include("http-server")
      expect(text).to include("tls-terminator")
      expect(text).to include("Web Tier")
    end

    it "is stable across reloads (identical input on re-embed)" do
      expect(node_module.embedding_text).to eq(described_class.find(node_module.id).embedding_text)
    end

    it "tolerates a module with no description, capabilities or category" do
      bare = create(:system_node_module, account: account, category: nil,
                    name: "bare-module", description: nil, capabilities: [])

      expect { bare.embedding_text }.not_to raise_error
      expect(bare.embedding_text).to include("bare-module")
    end

    it "truncates a runaway description rather than blowing the token budget" do
      verbose = create(:system_node_module, account: account, name: "verbose",
                       description: "x" * 5_000)

      expect(verbose.embedding_text.length).to be < 3_000
    end

    describe "scopes" do
      it "partitions rows by embedding presence" do
        embedded = create(:system_node_module, account: account, name: "embedded-one")
        pending  = create(:system_node_module, account: account, name: "pending-one")
        described_class.where(id: embedded.id)
                       .update_all(embedding: Array.new(1536, 0.1), embedding_generated_at: Time.current)

        expect(described_class.with_embedding.pluck(:id)).to include(embedded.id)
        expect(described_class.with_embedding.pluck(:id)).not_to include(pending.id)
        expect(described_class.without_embedding.pluck(:id)).to include(pending.id)
      end

      it "treats a row edited after its embedding as stale" do
        node_module.update_columns(embedding: Array.new(1536, 0.1),
                                   embedding_generated_at: 1.hour.ago,
                                   updated_at: Time.current)

        expect(described_class.embedding_stale.pluck(:id)).to include(node_module.id)
      end

      it "does not treat a freshly embedded row as stale" do
        node_module.update_columns(embedding: Array.new(1536, 0.1),
                                   updated_at: 1.hour.ago,
                                   embedding_generated_at: Time.current)

        expect(described_class.embedding_stale.pluck(:id)).not_to include(node_module.id)
      end
    end
  end

  describe System::NodeTemplate do
    subject(:template) do
      create(:system_node_template, account: account, node_platform: platform_record,
             name: "web-stack", description: "Public web serving stack")
    end

    let(:web) do
      create(:system_node_module, account: account, name: "nginx-proxy",
             description: "Reverse proxy fronting the application tier")
    end
    let(:cache) do
      create(:system_node_module, account: account, name: "redis-cache",
             description: "In-memory cache")
    end

    before do
      ::System::TemplateModule.create!(node_template: template, node_module: web)
      ::System::TemplateModule.create!(node_template: template, node_module: cache)
    end

    it "composes its own name and description" do
      text = template.embedding_text

      expect(text).to include("web-stack")
      expect(text).to include("Public web serving stack")
    end

    it "folds in the names and descriptions of its assigned modules" do
      text = template.reload.embedding_text

      expect(text).to include("nginx-proxy")
      expect(text).to include("Reverse proxy fronting the application tier")
      expect(text).to include("redis-cache")
      expect(text).to include("In-memory cache")
    end

    it "tolerates a template with no assigned modules" do
      empty = create(:system_node_template, account: account, node_platform: platform_record,
                     name: "empty-template", description: nil)

      expect { empty.embedding_text }.not_to raise_error
      expect(empty.embedding_text).to include("empty-template")
    end

    it "loads assigned modules without an N+1 per module" do
      3.times do |i|
        ::System::TemplateModule.create!(
          node_template: template,
          node_module: create(:system_node_module, account: account, name: "extra-#{i}")
        )
      end
      fresh = described_class.find(template.id)

      queries = 0
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        queries += 1 unless payload[:name].to_s.in?([ "SCHEMA", "TRANSACTION" ])
      end
      begin
        fresh.embedding_text
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end

      # One query to load the assigned modules — never one per module.
      expect(queries).to be <= 2
    end
  end
end
