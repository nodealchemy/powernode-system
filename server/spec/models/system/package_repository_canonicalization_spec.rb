# frozen_string_literal: true

require "rails_helper"

# T2.A — canonical-name storage for PackageRepository.architectures.
# Covers the before_validation hook + architectures_for_kind translation.
RSpec.describe System::PackageRepository, "T2.A canonicalization" do
  let(:account) { create(:account) }
  let(:user) { account.users.first || create(:user, account: account) }

  before { System::NodeArchitecture.ensure_canonical_seed! }

  def build_repo(kind:, architectures:, **overrides)
    defaults = {
      account:   account,
      created_by: user,
      name:      "t2a-#{kind}-#{SecureRandom.hex(3)}",
      kind:      kind,
      base_url:  "https://example.com/repo",
      architectures: architectures
    }
    if kind == "apt"
      defaults[:apt_config] = { "suite" => "noble", "components" => ["main"] }
    else
      defaults[:rpm_config] = { "releasever" => "40", "gpgcheck" => false }
    end
    System::PackageRepository.create!(defaults.merge(overrides))
  end

  describe "before_validation :canonicalize_architectures" do
    it "stores canonical names for an apt repo that already submits canonical" do
      repo = build_repo(kind: "apt", architectures: %w[amd64 arm64])
      expect(repo.reload.architectures).to eq(%w[amd64 arm64])
    end

    it "translates rpm-form input to canonical (rpm repo)" do
      repo = build_repo(kind: "rpm", architectures: %w[x86_64 aarch64])
      expect(repo.reload.architectures).to eq(%w[amd64 arm64])
    end

    it "translates rpm-form input to canonical (apt repo)" do
      # Defensive: even an apt repo whose JSONB somehow has rpm-form names
      # ends up canonical after the hook runs.
      repo = build_repo(kind: "apt", architectures: %w[x86_64 aarch64])
      expect(repo.reload.architectures).to eq(%w[amd64 arm64])
    end

    it "translates aliases to canonical" do
      arm = System::NodeArchitecture.find_by!(name: "arm64")
      arm.update!(aliases: ["amd64-graviton"])
      repo = build_repo(kind: "apt", architectures: %w[amd64 amd64-graviton])
      # amd64-graviton resolves to arm64 canonical → set becomes [amd64, arm64]
      expect(repo.reload.architectures).to match_array(%w[amd64 arm64])
    end

    it "drops unmappable values silently" do
      repo = build_repo(kind: "apt", architectures: %w[amd64 nonsense-junk])
      expect(repo.reload.architectures).to eq(%w[amd64])
    end

    it "deduplicates after canonicalization (two forms of the same arch)" do
      # x86_64 and amd64 both canonical to amd64
      repo = build_repo(kind: "apt", architectures: %w[amd64 x86_64])
      expect(repo.reload.architectures).to eq(%w[amd64])
    end
  end

  describe "#architectures_for_kind" do
    it "returns apt-form for an apt repo (canonical = apt-form for our 7 rows)" do
      repo = build_repo(kind: "apt", architectures: %w[amd64 arm64])
      expect(repo.architectures_for_kind).to eq(%w[amd64 arm64])
    end

    it "translates canonical to rpm-form for an rpm repo" do
      repo = build_repo(kind: "rpm", architectures: %w[amd64 arm64])
      expect(repo.architectures_for_kind).to eq(%w[x86_64 aarch64])
    end

    it "returns kind-specific names for the 7 canonical arches" do
      repo = build_repo(kind: "rpm", architectures: %w[amd64 arm64 armhf i386 ppc64el s390x riscv64])
      expect(repo.architectures_for_kind).to eq(%w[x86_64 aarch64 armv7hl i686 ppc64le s390x riscv64])
    end

    it "drops unmappable entries (defensive — shouldn't happen post-hook)" do
      # Bypass validation to inject a junk value, then verify for_kind drops it
      repo = build_repo(kind: "apt", architectures: ["amd64"])
      repo.update_column(:architectures, %w[amd64 not-a-real-arch])
      expect(repo.architectures_for_kind).to eq(["amd64"])
    end
  end

  describe "round-trip" do
    it "rpm repo: operator submits rpm-form → stored canonical → adapter receives rpm-form" do
      repo = build_repo(kind: "rpm", architectures: %w[x86_64 aarch64])
      expect(repo.reload.architectures).to eq(%w[amd64 arm64])           # stored canonical
      expect(repo.architectures_for_kind).to eq(%w[x86_64 aarch64])      # adapter gets rpm
    end

    it "apt repo: operator submits canonical → stored canonical → adapter receives canonical" do
      repo = build_repo(kind: "apt", architectures: %w[amd64 arm64])
      expect(repo.reload.architectures).to eq(%w[amd64 arm64])
      expect(repo.architectures_for_kind).to eq(%w[amd64 arm64])
    end
  end
end
