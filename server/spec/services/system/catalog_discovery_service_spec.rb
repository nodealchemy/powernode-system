# frozen_string_literal: true

require "rails_helper"

# IMP-67aea0728774 — semantic reuse-first discovery over the module/template
# catalogs. Mirrors System::Ai::Skills::DiscoverPackagesByIntentExecutor:
# pure pgvector cosine ranking with confidence buckets and NO lexical
# degradation (the premise of discovery IS the semantic match).
RSpec.describe System::CatalogDiscoveryService do
  let(:account)  { create(:account) }
  let(:platform_record) { create(:system_node_platform, account: account) }
  let(:near_vec) { Array.new(1536, 0.1) }
  let(:far_vec)  { Array.new(1536, -0.1) }

  before do
    allow_any_instance_of(::Ai::Memory::EmbeddingService)
      .to receive(:generate).and_return(near_vec)
  end

  def embed!(record, vector)
    record.class.where(id: record.id)
          .update_all(embedding: vector, embedding_generated_at: Time.current)
    record
  end

  describe ".discover_modules" do
    let!(:near) do
      embed!(create(:system_node_module, account: account, name: "nginx-proxy",
                    description: "reverse proxy"), near_vec)
    end
    let!(:far) do
      embed!(create(:system_node_module, account: account, name: "postgres",
                    description: "database"), far_vec)
    end

    it "ranks modules by cosine similarity, nearest first" do
      result = described_class.discover_modules(account: account, intent: "reverse proxy")

      expect(result.records.map(&:name).first).to eq("nginx-proxy")
    end

    it "buckets confidence off the top match's distance" do
      result = described_class.discover_modules(account: account, intent: "reverse proxy")

      expect(result.confidence).to eq("high")
    end

    it "reports low confidence when nothing is embedded" do
      ::System::NodeModule.update_all(embedding: nil, embedding_generated_at: nil)
      result = described_class.discover_modules(account: account, intent: "reverse proxy")

      expect(result.records).to be_empty
      expect(result.confidence).to eq("low")
    end

    it "raises rather than silently degrading when the provider yields no vector" do
      allow_any_instance_of(::Ai::Memory::EmbeddingService).to receive(:generate).and_return(nil)

      expect { described_class.discover_modules(account: account, intent: "anything") }
        .to raise_error(described_class::EmbeddingUnavailable)
    end

    it "rejects a blank intent" do
      expect { described_class.discover_modules(account: account, intent: "  ") }
        .to raise_error(ArgumentError, /intent/i)
    end

    it "clamps top_k to MAX_TOP_K" do
      result = described_class.discover_modules(account: account, intent: "x", top_k: 9_999)

      expect(result.records.size).to be <= described_class::MAX_TOP_K
    end

    it "excludes modules belonging to another account" do
      other = create(:account)
      embed!(create(:system_node_module, account: other, name: "secret-module"), near_vec)

      result = described_class.discover_modules(account: account, intent: "x")

      expect(result.records.map(&:name)).not_to include("secret-module")
    end

    it "filters by variety" do
      embed!(create(:system_node_module, account: account, name: "sub-module",
                    variety: "subscription"), near_vec)

      result = described_class.discover_modules(account: account, intent: "x", variety: "subscription")

      expect(result.records.map(&:variety).uniq).to eq([ "subscription" ])
    end

    it "excludes disabled modules unless asked for them" do
      embed!(create(:system_node_module, account: account, name: "retired-module",
                    enabled: false), near_vec)

      names = described_class.discover_modules(account: account, intent: "x").records.map(&:name)
      expect(names).not_to include("retired-module")

      all_names = described_class.discover_modules(account: account, intent: "x",
                                                   include_disabled: true).records.map(&:name)
      expect(all_names).to include("retired-module")
    end

    # The recorded platform lesson: a "completed" index can be 0% embedded and
    # status lies. Discovery therefore reports its own blind spot inline —
    # an empty result with 40 unembedded rows means "not indexed", not "absent".
    #
    # Counts are baseline-relative: creating an Account seeds a starter module
    # catalog (system-base, nginx, apache, ...), so absolute totals here would
    # be asserting the seed, not the coverage arithmetic.
    it "reports catalog coverage alongside the results" do
      baseline = ::System::NodeModule.where(account: account).enabled.count
      create(:system_node_module, account: account, name: "never-embedded")

      result = described_class.discover_modules(account: account, intent: "x")

      expect(result.coverage[:total]).to eq(baseline + 1)
      expect(result.coverage[:embedded]).to eq(2) # near + far, the only embedded rows
      expect(result.coverage[:unembedded]).to eq(baseline - 1)
    end

    # Coverage must be counted over the SAME filtered scope the search ran
    # against, or the numbers describe a catalog the caller did not search.
    # Pinned per-filter: a coverage count that silently ignores one filter is
    # most misleading exactly when the filter is what made the result empty.
    it "narrows coverage with the variety filter" do
      # Every SEEDED module is subscription-variety, so a config-variety row
      # must exist for the filtered and unfiltered counts to differ at all —
      # without one, a coverage count that ignored the filter would be
      # indistinguishable from a correct one. near/far are config by factory
      # default; this makes the requirement explicit rather than incidental,
      # and the `be <` guard below fails loudly if it ever stops holding.
      create(:system_node_module, account: account, name: "cfg-only", variety: "config")
      embed!(create(:system_node_module, account: account, name: "sub-embedded",
                    variety: "subscription"), near_vec)
      create(:system_node_module, account: account, name: "sub-pending",
             variety: "subscription")
      subscription_total = ::System::NodeModule
                           .where(account: account, variety: "subscription").enabled.count

      unfiltered = described_class.discover_modules(account: account, intent: "x")
      filtered   = described_class.discover_modules(account: account, intent: "x",
                                                    variety: "subscription")

      expect(filtered.coverage[:total]).to eq(subscription_total)
      expect(filtered.coverage[:total]).to be < unfiltered.coverage[:total]
      expect(filtered.coverage[:embedded]).to eq(1)   # only sub-embedded
      expect(filtered.coverage[:unembedded]).to eq(subscription_total - 1)
    end

    it "narrows coverage with the platform filter" do
      other_platform = create(:system_node_platform, account: account)
      embed!(create(:system_node_module, account: account, name: "platform-scoped",
                    node_platform: other_platform), near_vec)

      result = described_class.discover_modules(account: account, intent: "x",
                                                platform_id: other_platform.id)

      expect(result.coverage[:total])
        .to eq(::System::NodeModule.where(account: account, node_platform_id: other_platform.id).enabled.count)
      expect(result.coverage[:embedded]).to eq(1)
    end
  end

  describe ".discover_templates" do
    let!(:near) do
      embed!(create(:system_node_template, account: account, node_platform: platform_record,
                    name: "web-stack", description: "public web serving"), near_vec)
    end
    let!(:far) do
      embed!(create(:system_node_template, account: account, node_platform: platform_record,
                    name: "batch-stack", description: "nightly batch"), far_vec)
    end

    it "ranks templates by cosine similarity, nearest first" do
      result = described_class.discover_templates(account: account, intent: "web server")

      expect(result.records.map(&:name).first).to eq("web-stack")
    end

    it "excludes templates belonging to another account" do
      other = create(:account)
      other_platform = create(:system_node_platform, account: other)
      embed!(create(:system_node_template, account: other, node_platform: other_platform,
                    name: "secret-template"), near_vec)

      result = described_class.discover_templates(account: account, intent: "x")

      expect(result.records.map(&:name)).not_to include("secret-template")
    end

    it "raises rather than silently degrading when the provider yields no vector" do
      allow_any_instance_of(::Ai::Memory::EmbeddingService).to receive(:generate).and_return(nil)

      expect { described_class.discover_templates(account: account, intent: "anything") }
        .to raise_error(described_class::EmbeddingUnavailable)
    end

    it "reports catalog coverage alongside the results" do
      total = ::System::NodeTemplate.where(account: account, enabled: true).count

      result = described_class.discover_templates(account: account, intent: "x")

      expect(result.coverage[:total]).to eq(total)
      expect(result.coverage[:embedded]).to eq(2)
      expect(result.coverage[:unembedded]).to eq(total - 2)
    end
  end

  # IMP-a9adf9ea4399 — the 3x over-fetch was documented as headroom for
  # structured filters to whittle post-search, which no code does: every
  # filter is applied to the scope BEFORE nearest_neighbors runs. The fetch
  # is not useless though — it is what makes seed_count a "there is more
  # beyond top_k" signal rather than a restatement of the page size. These
  # pin that real meaning so the comments and the payload agree.
  describe "seed_count semantics" do
    before do
      5.times { |i| embed!(create(:system_node_module, account: account, name: "mod-#{i}"), near_vec) }
    end

    it "reports more candidates than the page when the catalog has them" do
      result = described_class.discover_modules(account: account, intent: "anything", top_k: 2)

      expect(result.records.size).to eq(2)
      expect(result.seed_count).to be > result.records.size
    end

    it "never exceeds the over-fetch bound" do
      result = described_class.discover_modules(account: account, intent: "anything", top_k: 2)

      expect(result.seed_count).to be <= 2 * described_class::SEMANTIC_OVERSCORE_FACTOR
    end
  end
end
