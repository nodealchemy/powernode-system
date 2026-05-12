# frozen_string_literal: true

require "rails_helper"

# T2.B — fleet-aware architecture suggestion for package materialization.
RSpec.describe System::Ai::Skills::SuggestArchitecturesForFleetExecutor do
  let(:account) { create(:account) }
  let(:exec)    { described_class.new(account: account) }

  # Build NodeArchitecture rows with explicit apt/rpm names so
  # `find_normalized` resolves repo arch strings ("amd64", "arm64",
  # "x86_64") back to the canonical row.
  def make_arch(name:, apt:, rpm:, family:, node_platforms: 0, packages: 0)
    create(
      :system_node_architecture,
      name:                  name,
      apt_name:              apt,
      rpm_name:              rpm,
      family:                family,
      is_canonical:          true,
      node_platform_count:   node_platforms,
      package_count:         packages,
    )
  end

  describe ".descriptor" do
    it "advertises required inputs + correct output shape" do
      d = described_class.descriptor

      expect(d[:name]).to eq("suggest_architectures_for_fleet")
      expect(d[:category]).to eq("devops")
      expect(d.dig(:inputs, :repository_id, :required)).to be true
      expect(d.dig(:inputs, :max_suggestions, :required)).to be false
      expect(d[:outputs].keys).to include(:repository_id, :suggested, :rationale, :fallback, :confidence)
    end
  end

  describe "#execute" do
    context "when the repository is not accessible to the account" do
      it "returns failure" do
        other_account = create(:account)
        repo = create(:system_package_repository, account: other_account)

        result = exec.execute(repository_id: repo.id)

        expect(result[:success]).to be false
        expect(result[:error]).to match(/not found|not accessible/i)
      end

      it "returns failure for non-existent repository_id" do
        result = exec.execute(repository_id: SecureRandom.uuid)

        expect(result[:success]).to be false
        expect(result[:error]).to match(/not found|not accessible/i)
      end
    end

    context "when the repository has no architectures configured" do
      it "returns an empty suggestion set with fallback + low confidence" do
        repo = create(:system_package_repository, account: account, architectures: [])

        result = exec.execute(repository_id: repo.id)

        expect(result[:success]).to be true
        expect(result[:data][:suggested]).to be_empty
        expect(result[:data][:fallback]).to be true
        expect(result[:data][:confidence]).to eq("low")
      end
    end

    context "when fleet has platforms for some of the repo's architectures" do
      let!(:amd64) { make_arch(name: "x86_64",  apt: "amd64", rpm: "x86_64",  family: "x86", node_platforms: 5, packages: 1_000) }
      let!(:arm64) { make_arch(name: "aarch64", apt: "arm64", rpm: "aarch64", family: "arm", node_platforms: 2, packages: 500) }
      let!(:i686)  { make_arch(name: "i686",    apt: "i386",  rpm: "i686",    family: "x86", node_platforms: 0, packages: 100) }

      let!(:repo) do
        create(:system_package_repository,
               account:       account,
               architectures: %w[amd64 arm64 i386])
      end

      it "ranks architectures by node_platform_count descending" do
        result = exec.execute(repository_id: repo.id)

        expect(result[:success]).to be true
        d = result[:data]
        expect(d[:fallback]).to be false
        expect(d[:suggested]).to eq(%w[x86_64 aarch64])  # i686 excluded (zero platforms)
        expect(d[:rationale].map { |r| r[:arch] }).to eq(%w[x86_64 aarch64])
      end

      it "reports high confidence when one arch clearly dominates" do
        # amd64 score = 5*10 + log10(1001) ≈ 53; arm64 = 2*10 + log10(501) ≈ 22.7
        # Ratio > 2x → high.
        result = exec.execute(repository_id: repo.id)
        expect(result[:data][:confidence]).to eq("high")
      end

      it "respects max_suggestions cap" do
        result = exec.execute(repository_id: repo.id, max_suggestions: 1)
        expect(result[:data][:suggested]).to eq(%w[x86_64])
      end

      it "clamps max_suggestions to [1, 7]" do
        too_low  = exec.execute(repository_id: repo.id, max_suggestions: 0)
        too_high = exec.execute(repository_id: repo.id, max_suggestions: 99)

        # 0 clamps up to 1
        expect(too_low[:data][:suggested].length).to eq(1)
        # 99 clamps down to 7, but only 2 archs have fleet coverage anyway
        expect(too_high[:data][:suggested].length).to eq(2)
      end

      it "annotates the top arch's rationale with the platform count" do
        result = exec.execute(repository_id: repo.id)
        top = result[:data][:rationale].first
        expect(top[:node_platforms]).to eq(5)
        expect(top[:reason]).to match(/top fleet arch/i).and match(/5 NodePlatforms/i)
      end
    end

    context "when fleet has roughly equal coverage across arches" do
      let!(:amd64) { make_arch(name: "x86_64",  apt: "amd64", rpm: "x86_64",  family: "x86", node_platforms: 5, packages: 1_000) }
      let!(:arm64) { make_arch(name: "aarch64", apt: "arm64", rpm: "aarch64", family: "arm", node_platforms: 5, packages: 1_000) }

      let!(:repo) do
        create(:system_package_repository,
               account:       account,
               architectures: %w[amd64 arm64])
      end

      it "reports medium confidence when top and runner-up are within 2x" do
        result = exec.execute(repository_id: repo.id)

        expect(result[:success]).to be true
        expect(result[:data][:suggested]).to match_array(%w[x86_64 aarch64])
        expect(result[:data][:confidence]).to eq("medium")
      end

      it "marks the runner-up as co-leading in its rationale" do
        result = exec.execute(repository_id: repo.id)
        reasons = result[:data][:rationale].map { |r| r[:reason] }
        expect(reasons.last).to match(/co-leading/i)
      end
    end

    context "when no fleet platforms cover any of the repo's architectures" do
      let!(:amd64) { make_arch(name: "x86_64",  apt: "amd64", rpm: "x86_64",  family: "x86", node_platforms: 0, packages: 1_000) }
      let!(:arm64) { make_arch(name: "aarch64", apt: "arm64", rpm: "aarch64", family: "arm", node_platforms: 0, packages: 500) }

      let!(:repo) do
        create(:system_package_repository,
               account:       account,
               architectures: %w[amd64 arm64])
      end

      it "falls back to the first 2 repo arches with low confidence" do
        result = exec.execute(repository_id: repo.id)

        expect(result[:success]).to be true
        d = result[:data]
        expect(d[:fallback]).to be true
        expect(d[:confidence]).to eq("low")
        expect(d[:suggested].length).to eq(2)
        expect(d[:rationale].first[:reason]).to match(/no fleet platforms/i)
      end
    end

    context "when repo arches don't resolve to any catalog row" do
      let!(:repo) do
        create(:system_package_repository,
               account:       account,
               architectures: %w[bogus-arch-name another-bogus])
      end

      it "returns empty suggestions with fallback flag" do
        result = exec.execute(repository_id: repo.id)

        expect(result[:success]).to be true
        expect(result[:data][:suggested]).to be_empty
        expect(result[:data][:fallback]).to be true
        expect(result[:data][:confidence]).to eq("low")
      end
    end

    context "when an rpm-style arch resolves via rpm_name lookup" do
      let!(:amd64) { make_arch(name: "x86_64", apt: "amd64", rpm: "x86_64", family: "x86", node_platforms: 3, packages: 800) }
      let!(:repo) do
        create(:system_package_repository, :rpm,
               account:       account,
               architectures: %w[x86_64])
      end

      it "resolves x86_64 via rpm_name + emits canonical name in suggestions" do
        result = exec.execute(repository_id: repo.id)

        expect(result[:success]).to be true
        expect(result[:data][:suggested]).to eq(%w[x86_64])
        expect(result[:data][:fallback]).to be false
      end
    end
  end
end
