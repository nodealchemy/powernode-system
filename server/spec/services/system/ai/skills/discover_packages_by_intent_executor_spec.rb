# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::Ai::Skills::DiscoverPackagesByIntentExecutor do
  let(:account) { create(:account) }
  let(:repo)    { create(:system_package_repository, account: account, name: "test-repo") }
  let(:executor) { described_class.new(account: account) }
  let(:fake_vec) { Array.new(1536, 0.1) }

  before do
    # Default: embedding succeeds and yields a deterministic vector.
    allow_any_instance_of(::Ai::Memory::EmbeddingService)
      .to receive(:generate).and_return(fake_vec)
  end

  def pkg(name, **opts)
    create(:system_package, package_repository: repo, name: name, **opts)
  end

  describe ".descriptor" do
    it "exposes the canonical inputs and outputs surface" do
      desc = described_class.descriptor
      expect(desc[:name]).to eq("discover_packages_by_intent")
      expect(desc[:category]).to eq("devops")
      expect(desc[:inputs].keys).to match_array(%i[intent repository_ids kind architectures license top_k])
      expect(desc[:outputs].keys).to match_array(%i[intent results seed_count confidence])
    end
  end

  describe "#execute" do
    context "input validation" do
      it "fails when intent is blank" do
        result = executor.execute(intent: "")
        expect(result[:success]).to be(false)
        expect(result[:error]).to match(/intent is required/i)
      end

      it "fails when account is nil" do
        result = described_class.new(account: nil).execute(intent: "anything")
        expect(result[:success]).to be(false)
        expect(result[:error]).to match(/account/i)
      end

      it "fails when embedding generation returns nil" do
        allow_any_instance_of(::Ai::Memory::EmbeddingService).to receive(:generate).and_return(nil)
        result = executor.execute(intent: "anything")
        expect(result[:success]).to be(false)
        expect(result[:error]).to match(/could not generate embedding/i)
      end
    end

    context "ranking + confidence" do
      before do
        # Two packages with embeddings — vec_close should rank first.
        vec_close = Array.new(1536, 0.1)
        vec_far   = Array.new(1536, -0.1)
        @near = pkg("nginx",  summary: "reverse proxy server")
        @far  = pkg("apache", summary: "httpd")
        ::System::Package.where(id: @near.id).update_all(embedding: vec_close)
        ::System::Package.where(id: @far.id).update_all(embedding: vec_far)
      end

      it "returns matches sorted by similarity (near vector first)" do
        result = executor.execute(intent: "reverse proxy", top_k: 5)
        expect(result[:success]).to be(true)
        names = result[:data][:results].map { |r| r[:name] }
        expect(names.first).to eq("nginx")
      end

      it "labels confidence based on top match's cosine distance" do
        result = executor.execute(intent: "reverse proxy", top_k: 5)
        # With identical vectors (vec_close == fake_vec), distance ~0 → high
        expect(result[:data][:confidence]).to eq("high")
      end

      it "includes per-result reason strings" do
        result = executor.execute(intent: "reverse proxy", top_k: 5)
        expect(result[:data][:results].first[:reason]).to match(/Semantic match for 'reverse proxy'/)
      end

      it "clamps top_k to [1, MAX_TOP_K]" do
        result = executor.execute(intent: "anything", top_k: 9_999)
        expect(result[:data][:results].size).to be <= described_class::MAX_TOP_K
      end
    end

    context "structured filters" do
      let(:other_repo) { create(:system_package_repository, account: account, name: "other") }

      before do
        @a = pkg("nginx-here")
        @b = create(:system_package, package_repository: other_repo, name: "nginx-other")
        ::System::Package.update_all(embedding: Array.new(1536, 0.1))
      end

      it "scopes by repository_ids" do
        result = executor.execute(intent: "x", repository_ids: [repo.id])
        names = result[:data][:results].map { |r| r[:name] }
        expect(names).to include("nginx-here")
        expect(names).not_to include("nginx-other")
      end
    end

    context "account isolation" do
      let(:other_account) { create(:account) }
      let(:other_repo)    { create(:system_package_repository, account: other_account, name: "private") }

      it "excludes packages from inaccessible repositories" do
        create(:system_package, package_repository: other_repo, name: "secret")
        ::System::Package.update_all(embedding: Array.new(1536, 0.1))
        result = executor.execute(intent: "x")
        names = result[:data][:results].map { |r| r[:name] }
        expect(names).not_to include("secret")
      end
    end
  end
end
