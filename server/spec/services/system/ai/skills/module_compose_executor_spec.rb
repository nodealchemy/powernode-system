# frozen_string_literal: true

require "rails_helper"

# Golden Eclipse M6.F + campaign 019f6084 inc3 — ModuleComposeExecutor v1.
# v1 ranks modules SEMANTICALLY (embedding cosine) with a keyword-overlap
# fallback, and bridges module gaps to package materialization.
#
# Embeddings are stubbed with a deterministic keyword-space projection so the
# semantic ranker is testable: each vocab word is one dimension, and a text's
# vector is the multi-hot of the vocab words it contains. Cosine similarity
# then tracks shared-keyword overlap — intuitive and reproducible.
RSpec.describe System::Ai::Skills::ModuleComposeExecutor do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }
  let(:exec)     { described_class.new(account: account) }

  VOCAB = %w[nginx certbot ssl proxy reverse redis instance postgresql web cache database memcached].freeze

  def kw_embed(text)
    toks = text.to_s.downcase.scan(/[a-z0-9]+/)
    vec = VOCAB.map { |w| toks.include?(w) ? 1.0 : 0.0 }
    vec.sum.zero? ? nil : vec
  end

  # Deterministic keyword-space embeddings + a comfortable similarity floor.
  def stub_semantic!
    allow_any_instance_of(::Ai::Memory::EmbeddingService)
      .to receive(:generate) { |_svc, text| kw_embed(text) }
    ::SiteSetting.set("system.module_compose.min_similarity", "0.3", setting_type: "string")
  end

  describe ".descriptor" do
    it "advertises description input, gap output, and Concierge binding" do
      d = described_class.descriptor
      expect(d[:name]).to eq("module_compose")
      expect(d.dig(:inputs, :description, :required)).to be true
      expect(d[:outputs].keys).to include(:gaps, :ranking_mode)
    end

    it "binds to Fleet Autonomy and System Concierge" do
      entry = System::Ai::Skills::SkillBindings.by_skill.find { |r| r[:executor] == described_class }
      expect(entry[:agents]).to include("Fleet Autonomy", "System Concierge")
    end
  end

  describe "#execute — semantic ranking" do
    before { stub_semantic! }

    context "with description matching multiple modules" do
      before do
        %w[nginx certbot postgresql].each do |module_name|
          ::System::NodeModule.find_or_create_by!(account: account, name: module_name) do |m|
            m.node_platform = platform
            m.category      = category
            m.variety       = "subscription"
            m.enabled       = true
            m.priority      = 50
          end
        end
      end

      it "ranks matches by semantic similarity and drops the off-topic module" do
        r = exec.execute(description: "nginx with certbot ssl termination")
        expect(r[:success]).to be true
        expect(r[:data][:ranking_mode]).to eq("semantic")
        names = r[:data][:draft_template][:modules].map { |m| m[:name] }
        expect(names).to include("nginx", "certbot")
        expect(names).not_to include("postgresql")
        expect(r[:data][:draft_template][:modules].first[:score]).to be > 0
      end

      it "suggests a hyphenated template name from description tokens" do
        r = exec.execute(description: "nginx web reverse proxy")
        expect(r[:data][:draft_template][:name_suggestion]).to match(/-template\z/)
      end
    end

    context "with two instance-variety modules in the same category" do
      let!(:instance_a) do
        create(:system_node_module, account: account, node_platform: platform,
               category: category, variety: "instance", name: "redis-instance-a")
      end
      let!(:instance_b) do
        create(:system_node_module, account: account, node_platform: platform,
               category: category, variety: "instance", name: "redis-instance-b")
      end

      it "flags an instance_variety_collision conflict" do
        r = exec.execute(description: "redis instance")
        conflicts = r[:data][:conflicts]
        expect(conflicts).not_to be_empty
        expect(conflicts.first[:kind]).to eq("instance_variety_collision")
      end
    end

    context "scoped to a specific platform_id" do
      let(:other_platform) { create(:system_node_platform, account: account) }

      before do
        create(:system_node_module, account: account, node_platform: platform,
               category: category, variety: "subscription", name: "nginx-here")
        create(:system_node_module, account: account, node_platform: other_platform,
               category: category, variety: "subscription", name: "nginx-elsewhere")
      end

      it "limits candidates to the given platform" do
        r = exec.execute(description: "nginx web proxy", platform_id: platform.id)
        names = r[:data][:draft_template][:modules].map { |m| m[:name] }
        expect(names).to include("nginx-here")
        expect(names).not_to include("nginx-elsewhere")
      end
    end
  end

  describe "#execute — gap bridging" do
    before { stub_semantic! }

    it "surfaces a materialize gap when no module covers the capability" do
      # No memcached module exists → nothing clears the floor → gap bridge.
      # discover_packages_by_intent is stubbed to return a memcached package.
      allow_any_instance_of(System::Ai::Skills::DiscoverPackagesByIntentExecutor)
        .to receive(:execute).and_return(
          { success: true,
            data: { results: [ { name: "memcached", package_id: "pkg-1", repository_id: "repo-1" } ],
                    confidence: "high" } }
        )

      r = exec.execute(description: "memcached distributed cache")
      expect(r[:success]).to be true
      expect(r[:data][:draft_template][:modules]).to be_empty
      gaps = r[:data][:gaps]
      expect(gaps.size).to eq(1)
      expect(gaps.first[:action]).to eq("materialize")
      expect(gaps.first[:package]).to eq("memcached")
      expect(gaps.first[:repository_id]).to eq("repo-1")
    end

    it "surfaces a gap for the UNCOVERED capability under partial coverage" do
      # "nginx + redis": nginx has a covering module, redis does not. The prior
      # all-or-nothing `return [] if chosen.any?` silently dropped redis; now
      # the request decomposes per-capability and redis surfaces its own gap.
      ::System::NodeModule.find_or_create_by!(account: account, name: "nginx") do |m|
        m.node_platform = platform
        m.category      = category
        m.variety       = "subscription"
        m.enabled       = true
        m.priority      = 50
      end
      allow_any_instance_of(System::Ai::Skills::DiscoverPackagesByIntentExecutor)
        .to receive(:execute).and_return(
          { success: true,
            data: { results: [ { name: "redis", package_id: "pkg-redis", repository_id: "repo-redis" } ],
                    confidence: "high" } }
        )

      r = exec.execute(description: "nginx + redis")
      expect(r[:success]).to be true

      # nginx is still composed (partial coverage, not dropped) ...
      names = r[:data][:draft_template][:modules].map { |m| m[:name] }
      expect(names).to include("nginx")

      # ... and the uncovered redis capability surfaces a materialize gap.
      gaps = r[:data][:gaps]
      materialize = gaps.find { |g| g[:action] == "materialize" && g[:package] == "redis" }
      expect(materialize).to be_present
      expect(materialize[:capability]).to eq("redis")
      expect(materialize[:repository_id]).to eq("repo-redis")
    end
  end

  describe "#execute — keyword fallback" do
    before do
      # Embedding provider unavailable → generate returns nil → keyword mode.
      allow_any_instance_of(::Ai::Memory::EmbeddingService).to receive(:generate).and_return(nil)
      ::System::NodeModule.find_or_create_by!(account: account, name: "nginx") do |m|
        m.node_platform = platform
        m.category      = category
        m.variety       = "subscription"
        m.enabled       = true
        m.priority      = 50
      end
    end

    it "degrades to keyword overlap ranking" do
      r = exec.execute(description: "nginx web server")
      expect(r[:success]).to be true
      expect(r[:data][:ranking_mode]).to eq("keyword")
      names = r[:data][:draft_template][:modules].map { |m| m[:name] }
      expect(names).to include("nginx")
    end
  end

  describe "#execute — input validation" do
    it "fails fast on a stopword-only description" do
      r = exec.execute(description: "the and a is")
      expect(r[:success]).to be false
      expect(r[:error]).to match(/at least one non-stopword/)
    end
  end
end
