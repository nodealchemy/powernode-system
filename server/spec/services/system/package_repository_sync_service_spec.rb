# frozen_string_literal: true

require "rails_helper"

# Change-detection + fingerprint fast-path throughput work. The adapter is
# STUBBED — no live mirror — so these assert the service's write behavior:
# what it inserts/obsoletes/reactivates/skips, the unchanged-repo zero-write
# contract, the mass-obsoletion guard, and the apt-vs-rpm path split.
RSpec.describe System::PackageRepositorySyncService do
  let(:account) { create(:account) }
  let(:repo)    { create(:system_package_repository, account: account, kind: "apt") }

  def parsed(name, version, arch: "amd64", **extra)
    System::PackageAdapters::Base::ParsedPackage.new(
      name: name, version: version, architecture: arch,
      description: extra[:description], summary: extra[:summary],
      depends: extra[:depends] || [], pre_depends: [], recommends: [], suggests: [],
      conflicts: [], provides: [], replaces: [], breaks: [], raw_metadata: {}
    )
  end

  # Fake adapter yielding `packages` and returning `fingerprint`.
  def stub_adapter(packages:, fingerprint: "FP", kind: "apt")
    adapter = Object.new
    adapter.define_singleton_method(:fingerprint) { |repository:| fingerprint }
    adapter.define_singleton_method(:sync_metadata) do |repository:, architectures:, &blk|
      packages.each { |p| blk.call(p) }
      packages.size
    end
    allow(System::PackageAdapters).to receive(:for).with(kind: kind).and_return(adapter)
    adapter
  end

  before do
    allow(System::WorkerJobEnqueuer).to receive(:enqueue)
    allow(System::NodeArchitecture).to receive(:recompute_package_counts!)
  end

  def key_set(repo)
    System::Package.where(package_repository_id: repo.id, obsoleted_at: nil)
                   .pluck(:name, :version).to_set
  end

  describe "fingerprint fast-path" do
    it "skips fetch/parse entirely when the fingerprint is unchanged" do
      repo.update_columns(sync_fingerprint: "SAME", parser_version: described_class::PARSER_VERSION)
      create(:system_package, package_repository: repo, name: "keep", version: "1")
      adapter = stub_adapter(packages: [ parsed("ignored", "9") ], fingerprint: "SAME")
      expect(adapter).not_to receive(:sync_metadata)

      result = described_class.call(repository: repo)

      expect(result.success?).to be true
      expect(result.upserted).to eq(0)
      expect(key_set(repo)).to eq(Set[ %w[keep 1] ]) # untouched — no obsoletion
    end

    it "does a full sync when the fingerprint changed" do
      repo.update_columns(sync_fingerprint: "OLD", parser_version: described_class::PARSER_VERSION)
      stub_adapter(packages: [ parsed("a", "1") ], fingerprint: "NEW")

      described_class.call(repository: repo)

      expect(repo.reload.sync_fingerprint).to eq("NEW")
      expect(key_set(repo)).to eq(Set[ %w[a 1] ])
    end
  end

  describe "apt change-detection" do
    it "first sync inserts every package" do
      stub_adapter(packages: [ parsed("a", "1"), parsed("b", "2") ])
      result = described_class.call(repository: repo)
      expect(result.upserted).to eq(2)
      expect(key_set(repo)).to eq(Set[ %w[a 1], %w[b 2] ])
    end

    it "no-change re-sync writes NOTHING (the whole point)" do
      a = create(:system_package, package_repository: repo, name: "a", version: "1")
      b = create(:system_package, package_repository: repo, name: "b", version: "2")
      repo.update_columns(sync_fingerprint: "OLD", parser_version: described_class::PARSER_VERSION)
      stub_adapter(packages: [ parsed("a", "1"), parsed("b", "2") ], fingerprint: "NEW")

      before_a = a.reload.updated_at
      before_b = b.reload.updated_at
      result = described_class.call(repository: repo)

      expect(result.upserted).to eq(0)
      expect(result.obsoleted).to eq(0)
      # untouched rows keep their updated_at → no rewrite / no index churn
      expect(a.reload.updated_at).to eq(before_a)
      expect(b.reload.updated_at).to eq(before_b)
    end

    it "inserts new, obsoletes vanished, reactivates reappeared" do
      # 10 stable keeps so the single vanish stays under the obsoletion guard.
      keeps = Array.new(10) { |i| "keep#{i}" }
      keeps.each { |n| create(:system_package, package_repository: repo, name: n, version: "1") }
      create(:system_package, package_repository: repo, name: "gone", version: "1")
      create(:system_package, package_repository: repo, name: "back", version: "1", obsoleted_at: 1.day.ago)
      repo.update_columns(sync_fingerprint: "OLD", parser_version: described_class::PARSER_VERSION)
      upstream = keeps.map { |n| parsed(n, "1") } + [ parsed("back", "1"), parsed("new", "1") ]
      stub_adapter(packages: upstream, fingerprint: "NEW")

      described_class.call(repository: repo)

      expect(System::Package.find_by(package_repository_id: repo.id, name: "gone").obsoleted_at).to be_present
      expect(System::Package.find_by(package_repository_id: repo.id, name: "back").obsoleted_at).to be_nil
      expect(System::Package.find_by(package_repository_id: repo.id, name: "new")).to be_present
    end

    it "processes an intra-index duplicate key once" do
      repo.update_columns(parser_version: described_class::PARSER_VERSION)
      stub_adapter(packages: [ parsed("dup", "1"), parsed("dup", "1") ])
      result = described_class.call(repository: repo)
      expect(result.upserted).to eq(1)
    end
  end

  describe "mass-obsoletion guard (partial/empty upstream)" do
    it "refuses when the upstream yields zero packages" do
      create(:system_package, package_repository: repo, name: "a", version: "1")
      repo.update_columns(sync_fingerprint: "OLD")
      stub_adapter(packages: [], fingerprint: "NEW")

      result = described_class.call(repository: repo)

      expect(result.success?).to be false
      expect(result.error).to match(/zero packages|refusing/i)
      expect(key_set(repo)).to eq(Set[ %w[a 1] ]) # NOT obsoleted
      expect(repo.reload.sync_status).to eq("failed")
    end

    it "refuses when more than the guard fraction would be obsoleted" do
      10.times { |i| create(:system_package, package_repository: repo, name: "p#{i}", version: "1") }
      repo.update_columns(sync_fingerprint: "OLD")
      stub_adapter(packages: [ parsed("p0", "1") ], fingerprint: "NEW") # 9/10 vanish

      result = described_class.call(repository: repo)

      expect(result.success?).to be false
      expect(result.error).to match(/refusing|obsolete/i)
      expect(System::Package.where(package_repository_id: repo.id, obsoleted_at: nil).count).to eq(10)
    end

    it "force overrides the guard (mass obsoletion allowed)" do
      10.times { |i| create(:system_package, package_repository: repo, name: "p#{i}", version: "1") }
      stub_adapter(packages: [ parsed("p0", "1") ], fingerprint: "NEW")

      result = described_class.call(repository: repo, force: true)

      # Without force this 90%-obsoletion would raise SyncGuardError; force
      # lets it through (success, and the mass obsoletion actually happened).
      expect(result.success?).to be true
      expect(result.obsoleted).to be >= 9
    end
  end

  describe "rpm uses the full-upsert path (does NOT skip existing)" do
    let(:repo) { create(:system_package_repository, :rpm, account: account) }

    it "rewrites an existing row (rpm version isn't a full immutable identity)" do
      pkg = create(:system_package, package_repository: repo, name: "glibc", version: "2.34",
                   architecture: "x86_64", description: "old")
      repo.update_columns(sync_fingerprint: "OLD")
      stub_adapter(packages: [ parsed("glibc", "2.34", arch: "x86_64", description: "new") ],
                   fingerprint: "NEW", kind: "rpm")

      described_class.call(repository: repo)

      expect(pkg.reload.description).to eq("new") # full path refreshed it
    end
  end

  describe "force" do
    it "rewrites every row + re-enqueues embeddings even with no new packages" do
      create(:system_package, package_repository: repo, name: "a", version: "1")
      stub_adapter(packages: [ parsed("a", "1") ])
      expect(System::WorkerJobEnqueuer).to receive(:enqueue)
        .with(hash_including(job_class: "SystemPackageEmbeddingJob"))

      described_class.call(repository: repo, force: true)
    end
  end
end
