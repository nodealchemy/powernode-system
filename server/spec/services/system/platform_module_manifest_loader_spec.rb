# frozen_string_literal: true

require "rails_helper"

# F7-03: the platform-module seed reads modules/ straight off disk, so
# resurrection debris (untracked pre-rename module dirs restored by the
# unidentified cloud-sync) would re-enter the catalog on the next seed
# run. The loader must only admit git-tracked manifests when git
# tracking information is available.
RSpec.describe System::PlatformModuleManifestLoader do
  let(:root) { described_class::DEFAULT_ROOT }

  it "loads the tracked platform module manifests" do
    manifests = described_class.load_from_disk

    expect(manifests).to include("postgres-primary", "redis", "runtime-ruby")
    expect(manifests["postgres-primary"]).to include("name:")
  end

  it "excludes untracked module directories (resurrection-debris guard)" do
    debris = File.join(root, "zz-debris-#{SecureRandom.hex(4)}")
    FileUtils.mkdir_p(debris)
    File.write(File.join(debris, "manifest.yaml"), "name: zz-debris\nversion: 0.0.1\n")

    manifests = described_class.load_from_disk

    expect(manifests.keys).not_to include(File.basename(debris))
  ensure
    FileUtils.rm_rf(debris)
  end

  it "falls back to unfiltered disk reads when git tracking info is unavailable" do
    allow(described_class).to receive(:git_tracked_dirs).and_return(nil)

    manifests = described_class.load_from_disk

    expect(manifests).to include("postgres-primary")
  end
end
