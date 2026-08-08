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

  describe ".git_tracked_dirs" do
    # IMP-623f671b4826: the rescue used to return nil with no trace. nil is a
    # documented outcome (no git binary / not a work tree), but reaching it via
    # an exception also covers transient failures (ENOMEM, EACCES, disk
    # pressure) — and a nil here disarms the F7-03 guard above, so it must
    # leave an operator-visible line like every other rescue in the
    # module-management services.
    it "logs a warning when the git probe raises, so a disarmed guard leaves a trace" do
      allow(::IO).to receive(:popen).and_raise(Errno::ENOMEM)
      expect(Rails.logger).to receive(:warn)
        .with(/git tracking unavailable.*Errno::ENOMEM.*F7-03/).at_least(:once)

      expect(described_class.git_tracked_dirs(root)).to be_nil
    end

    it "stays silent on the clean not-a-work-tree path (nonzero git exit, no exception)" do
      Dir.mktmpdir do |bare_dir|
        expect(Rails.logger).not_to receive(:warn)

        expect(described_class.git_tracked_dirs(bare_dir)).to be_nil
      end
    end
  end
end
