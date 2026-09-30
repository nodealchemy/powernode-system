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
        expect(link.errors[:node_platform]).to eq([ "must exist" ])
      end

      # IMP-156eb1a7bdbc fix round (critic A M2) — the create/update doors
      # pass a raw node_platform_id to create!. A foreign id must fail with
      # the SAME error the required belongs_to gives a nonexistent id, or the
      # difference tells a tenant another tenant's platform exists.
      it "rejects a foreign platform exactly as it rejects a nonexistent one" do
        foreign = described_class.new(package_repository: repo, node_platform_id: platform_b.id)
        missing = described_class.new(package_repository: repo, node_platform_id: SecureRandom.uuid)

        expect(foreign).not_to be_valid
        expect(missing).not_to be_valid
        expect(foreign.errors.full_messages).to eq(missing.errors.full_messages)
        expect(foreign.errors.details).to eq(missing.errors.details)
      end

      # IMP-156eb1a7bdbc — the message is rendered to the caller (the
      # controller's render_validation_error, the MCP tool's full_messages),
      # so it must not name the OTHER tenant's account id — nor, for
      # symmetry, the caller's own.
      it "does not name either account id in the rejection" do
        link = described_class.new(package_repository: repo, node_platform: platform_b)
        link.valid?

        text = link.errors.full_messages.join(" ")
        expect(text).not_to include(account_b.id)
        expect(text).not_to include(account_a.id)
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
      expect(repo.node_platforms.map(&:id)).to match_array([ platform_a.id, other_platform.id ])
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
      expect(platform_a.package_repositories.map(&:id)).to match_array([ repo_a.id, repo_b.id ])
    end

    it "destroys join rows when the parent platform is destroyed" do
      described_class.create!(package_repository: repo_a, node_platform: platform_a)
      expect { platform_a.destroy }.to change(described_class, :count).by(-1)
    end
  end
end
