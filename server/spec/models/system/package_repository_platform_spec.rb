# frozen_string_literal: true

require "rails_helper"

# M:N PackageRepository ↔ NodePlatform.
# Cross-account integrity is the load-bearing invariant — a CHECK constraint
# can't express "shared repos link anywhere; account repos link same-account
# only," so the model carries that rule.
RSpec.describe System::PackageRepositoryPlatform do
  let(:account_a)  { create(:account) }
  let(:account_b)  { create(:account) }
  let(:platform_a) { create(:system_node_platform, account: account_a) }
  let(:platform_b) { create(:system_node_platform, account: account_b) }

  describe "association validation" do
    context "with an account-scoped repository" do
      let(:repo) { create(:system_package_repository, account: account_a) }

      it "permits linking to a same-account platform" do
        link = described_class.new(package_repository: repo, node_platform: platform_a)
        expect(link).to be_valid
        expect { link.save! }.not_to raise_error
      end

      it "rejects linking to a different-account platform" do
        link = described_class.new(package_repository: repo, node_platform: platform_b)
        expect(link).not_to be_valid
        expect(link.errors[:node_platform].first).to match(/same account/i)
      end
    end

    context "with a shared repository" do
      let(:shared_repo) { create(:system_package_repository, :shared, created_by: create(:user, account: account_a)) }

      it "permits linking to any-account platform (account_a)" do
        link = described_class.new(package_repository: shared_repo, node_platform: platform_a)
        expect(link).to be_valid
      end

      it "permits linking to any-account platform (account_b)" do
        link = described_class.new(package_repository: shared_repo, node_platform: platform_b)
        expect(link).to be_valid
      end
    end
  end

  describe "uniqueness" do
    let(:repo) { create(:system_package_repository, account: account_a) }

    it "rejects duplicate (repo, platform) pairs" do
      described_class.create!(package_repository: repo, node_platform: platform_a)
      dup = described_class.new(package_repository: repo, node_platform: platform_a)
      expect(dup).not_to be_valid
      expect(dup.errors[:package_repository_id].first).to match(/already linked/i)
    end
  end

  describe "PackageRepository#node_platforms" do
    let(:repo) { create(:system_package_repository, account: account_a) }
    let(:other_platform) { create(:system_node_platform, account: account_a) }

    it "returns all linked platforms via has_many :through" do
      described_class.create!(package_repository: repo, node_platform: platform_a)
      described_class.create!(package_repository: repo, node_platform: other_platform)
      expect(repo.node_platforms.map(&:id)).to match_array([platform_a.id, other_platform.id])
    end

    it "destroys join rows when the parent repository is destroyed" do
      described_class.create!(package_repository: repo, node_platform: platform_a)
      expect { repo.destroy }.to change(described_class, :count).by(-1)
    end
  end

  describe "NodePlatform#package_repositories" do
    let(:repo_a) { create(:system_package_repository, account: account_a) }
    let(:repo_b) { create(:system_package_repository, account: account_a) }

    it "returns all linked repositories via has_many :through" do
      described_class.create!(package_repository: repo_a, node_platform: platform_a)
      described_class.create!(package_repository: repo_b, node_platform: platform_a)
      expect(platform_a.package_repositories.map(&:id)).to match_array([repo_a.id, repo_b.id])
    end

    it "destroys join rows when the parent platform is destroyed" do
      described_class.create!(package_repository: repo_a, node_platform: platform_a)
      expect { platform_a.destroy }.to change(described_class, :count).by(-1)
    end
  end
end
