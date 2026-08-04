# frozen_string_literal: true

require "rails_helper"

# IMP-67aea0728774 — bounded-batch backfill for the module/template catalog
# embeddings, plus the coverage counters the operator rake task prints.
RSpec.describe System::CatalogEmbeddingBackfillService do
  let(:account) { create(:account) }
  let(:platform_record) { create(:system_node_platform, account: account) }
  let(:vec) { Array.new(1536, 0.1) }

  # Creating an Account seeds a starter module + template catalog, so counts
  # below are relative to that baseline rather than absolute.
  let(:module_count)   { ::System::NodeModule.where(account: account).count }
  let(:template_count) { ::System::NodeTemplate.where(account: account).count }

  before do
    allow_any_instance_of(::Ai::Memory::EmbeddingService)
      .to receive(:generate_batch) { |_svc, texts| texts.map { vec } }
  end

  describe ".call" do
    it "embeds unembedded modules and stamps embedding_generated_at" do
      mod = create(:system_node_module, account: account, name: "nginx-proxy")

      result = described_class.call(account: account, kinds: [ :modules ])

      expect(result.processed).to eq(module_count)
      expect(result.errors).to be_empty
      expect(result.remaining).to eq(0)
      mod.reload
      expect(mod.embedding).to be_present
      expect(mod.embedding_generated_at).to be_present
    end

    it "embeds templates too" do
      template = create(:system_node_template, account: account, node_platform: platform_record)

      described_class.call(account: account, kinds: [ :templates ])

      expect(template.reload.embedding).to be_present
    end

    it "is idempotent — a second run re-embeds nothing" do
      create(:system_node_module, account: account, name: "nginx-proxy")

      described_class.call(account: account, kinds: [ :modules ])
      second = described_class.call(account: account, kinds: [ :modules ])

      expect(second.processed).to eq(0)
    end

    it "re-embeds everything under force" do
      create(:system_node_module, account: account, name: "nginx-proxy")
      described_class.call(account: account, kinds: [ :modules ])

      forced = described_class.call(account: account, kinds: [ :modules ], force: true)

      expect(forced.processed).to eq(module_count)
    end

    it "picks up a row edited after it was embedded" do
      mod = create(:system_node_module, account: account, name: "nginx-proxy")
      described_class.call(account: account, kinds: [ :modules ])

      # A later edit makes the stored vector stale — the next pass must redo it.
      ::System::NodeModule.where(id: mod.id).update_all(updated_at: 1.minute.from_now)

      expect(described_class.call(account: account, kinds: [ :modules ]).processed).to eq(1)
    end

    it "honors the batch limit" do
      3.times { |i| create(:system_node_module, account: account, name: "mod-#{i}") }
      total = module_count

      result = described_class.call(account: account, kinds: [ :modules ], limit: 2)

      expect(result.processed).to eq(2)
      expect(result.remaining).to eq(total - 2)
    end

    it "records a per-row error and leaves the row unembedded when no vector comes back" do
      create(:system_node_module, account: account, name: "nginx-proxy")
      allow_any_instance_of(::Ai::Memory::EmbeddingService)
        .to receive(:generate_batch) { |_svc, texts| texts.map { nil } }

      result = described_class.call(account: account, kinds: [ :modules ])

      expect(result.processed).to eq(0)
      expect(result.errors.size).to eq(module_count)
      expect(::System::NodeModule.where(account: account).with_embedding.count).to eq(0)
    end

    # NodeModule#embedding_text reads category&.name, so composing a batch
    # without preloading fires one category query per module — on the one path
    # that iterates the whole catalog.
    it "preloads categories rather than issuing one query per module" do
      5.times do |i|
        create(:system_node_module, account: account, name: "cat-mod-#{i}",
               category: create(:system_node_module_category, account: account))
      end

      category_queries = 0
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        next if payload[:name].to_s.in?([ "SCHEMA", "TRANSACTION" ])

        category_queries += 1 if payload[:sql].to_s.include?("system_node_module_categories")
      end
      begin
        described_class.call(account: account, kinds: [ :modules ])
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end

      # One preload per batch, not one per module (the catalog here is a
      # single batch, so anything above a small constant is an N+1).
      expect(category_queries).to be <= 2
    end

    it "does not touch another account's rows" do
      other = create(:account)
      foreign = create(:system_node_module, account: other, name: "foreign")

      described_class.call(account: account, kinds: [ :modules ])

      expect(foreign.reload.embedding).to be_nil
    end
  end

  describe ".coverage" do
    it "counts total, embedded, stale and pending per kind" do
      embedded = create(:system_node_module, account: account, name: "embedded-one")
      create(:system_node_module, account: account, name: "pending-one")
      ::System::NodeModule.where(id: embedded.id)
                          .update_all(embedding: Array.new(1536, 0.1),
                                      embedding_generated_at: Time.current,
                                      updated_at: 1.hour.ago)
      create(:system_node_template, account: account, node_platform: platform_record)
      modules   = module_count
      templates = template_count

      coverage = described_class.coverage(account: account)

      expect(coverage[:modules][:total]).to eq(modules)
      expect(coverage[:modules][:embedded]).to eq(1)
      expect(coverage[:modules][:pending]).to eq(modules - 1)
      expect(coverage[:modules][:percent]).to eq(((1.0 / modules) * 100).round(1))
      expect(coverage[:templates][:total]).to eq(templates)
      expect(coverage[:templates][:embedded]).to eq(0)
    end

    it "counts a row edited after embedding as stale, not as covered" do
      mod = create(:system_node_module, account: account, name: "drifted")
      ::System::NodeModule.where(id: mod.id)
                          .update_all(embedding: Array.new(1536, 0.1),
                                      embedding_generated_at: 1.hour.ago,
                                      updated_at: Time.current)

      coverage = described_class.coverage(account: account)

      expect(coverage[:modules][:embedded]).to eq(1)
      expect(coverage[:modules][:stale]).to eq(1)
    end

    it "reports zero percent without dividing by zero on an empty catalog" do
      empty_account = create(:account)
      # NodeModule ⇄ NodeModuleVersion is a circular FK (current_version_id
      # points back at a version that points at the module), so the link has to
      # be broken before either side can go.
      scope = ::System::NodeModule.where(account: empty_account)
      scope.update_all(current_version_id: nil)
      scope.destroy_all

      coverage = described_class.coverage(account: empty_account)

      expect(coverage[:modules][:total]).to eq(0)
      expect(coverage[:modules][:percent]).to eq(0.0)
    end
  end
end
