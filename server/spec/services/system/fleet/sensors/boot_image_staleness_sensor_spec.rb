# frozen_string_literal: true

require "rails_helper"

# IMP-e840a570a371 — nothing measured the ACTIVE boot image against the code
# that decides its contents.
#
# BootImageDriftSensor compares a NODE's booted sha to the active sha and is
# correct about that. It is also why this gap survived nineteen days: an image
# three weeks behind the commit that force-included the wireguard/vrf/dummy
# netdev modules left every fleet node unable to create a WireGuard interface,
# and every node reported NOT drifted, because they all matched the stale
# pointer exactly. A fleet-wide capability gap read as green.
#
# TWO THINGS THESE EXAMPLES EXIST TO PIN, both of which an earlier draft of the
# sensor got wrong and a green suite did not notice:
#
#   1. The comparison is REACHABILITY, not sha equality. The image build fires
#      on a TAG push and records github.sha; the head of initramfs/ is a
#      different commit except by coincidence, so an equality test fires the
#      moment a fresh image is promoted and never stops.
#   2. The active image is the PLATFORM POINTER, not "the newest published
#      row". Retention keeps several published rows, so after a rollback the
#      newest one is an image nothing boots.
RSpec.describe System::Fleet::Sensors::BootImageStalenessSensor do
  let(:account) { create(:account) }
  let(:platform) { create(:system_node_platform, account: account, disk_image_git_sha: active_sha) }

  let(:active_sha) { "1233cb9e" + ("a" * 32) }
  let(:head_sha)   { "fe5c8da4" + ("b" * 32) }

  let(:provider) { create(:devops_git_provider, account: account, provider_type: "gitea") }
  let(:credential) { create(:devops_git_provider_credential, account: account, provider: provider) }
  let(:repository) do
    create(:devops_git_repository, account: account, owner: "powernode", name: "powernode-system",
           credential: credential)
  end

  # Raw Gitea shape: list_commits does NO normalization, so string keys with a
  # nested "commit" hash is what the endpoint actually returns.
  let(:head_commits) do
    [ { "sha" => head_sha, "commit" => { "committer" => { "date" => "2026-08-20T21:23:56+02:00" } } } ]
  end

  # compare_commits DOES normalize — symbol keys, flat :message. The sensor
  # tolerates both shapes; this fixture is the one production actually produces.
  let(:comparison) do
    { commits: [ { sha: head_sha, message: "fix(initramfs): force-include netdev modules\n\nbody" } ] }
  end

  let(:git_client) do
    instance_double(::Devops::Git::ApiClient, list_commits: head_commits, compare_commits: comparison)
  end

  before do
    SiteSetting.set("system.disk_image.source_repo", "powernode/powernode-system")
    # Both are lazy lets and most examples never name them directly; without
    # this the sensor would find no platform to assess and every positive
    # example would pass for the wrong reason (an empty scope emits nothing,
    # which is indistinguishable from "not stale").
    repository
    platform
    allow(::Devops::Git::ApiClient).to receive(:for).and_return(git_client)
    Rails.cache.clear
  end

  def signals
    described_class.new(account: account).sense
  end

  def kinds
    signals.map(&:kind)
  end

  describe "when the image-defining paths have moved past the active image" do
    it "emits one stale signal carrying both shas and the gap size" do
      emitted = signals

      expect(emitted.size).to eq(1)
      expect(emitted.first.kind).to eq("system.boot_image_stale")
      payload = emitted.first.payload
      expect(payload["active_git_sha"]).to eq(active_sha)
      expect(payload["head_git_sha"]).to eq(head_sha)
      expect(payload["commits_behind"]).to eq(1)
      expect(payload["commits"].first["message"]).to include("force-include netdev modules")
    end

    it "is deduped per platform" do
      expect(signals.first.fingerprint).to eq("boot_image_stale:#{platform.id}")
    end

    # THE DESIGN PREMISE. Without this the sensor could drop `path:` entirely,
    # compare against the branch TIP, and pass every other example here — which
    # is the exact behaviour the class comment says makes it worthless.
    it "asks git for the head of the image-defining paths, not the branch tip" do
      signals

      expect(git_client).to have_received(:list_commits)
        .with("powernode", "powernode-system", hash_including(sha: "develop", path: "initramfs"))
      expect(git_client).to have_received(:list_commits)
        .with("powernode", "powernode-system",
              hash_including(path: ".gitea/workflows/build-disk-image.yaml"))
    end

    it "reports an exact count even when the commit list is truncated" do
      many = Array.new(50) { |i| { sha: "#{i}" * 8, message: "c#{i}" } }
      allow(git_client).to receive(:compare_commits).and_return({ commits: many })

      payload = signals.first.payload
      expect(payload["commits_behind"]).to eq(50)
      expect(payload["commits"].size).to eq(described_class::MAX_LISTED_COMMITS)
      expect(payload["truncated"]).to be true
    end
  end

  # THE ABSENCE HALF — and the reachability premise.
  describe "when the head of those paths is already in the active image" do
    # The shas DIFFER (tag commit vs. last initramfs commit) and the image is
    # nonetheless current. An equality-based sensor emits here; that is the
    # false positive this example exists to forbid.
    it "emits nothing, even though the two shas are not equal" do
      allow(git_client).to receive(:compare_commits).and_return({ commits: [] })

      expect(signals).to be_empty
    end
  end

  describe "which publication counts as the active image" do
    # After a rollback the pointer moves back while a NEWER published row
    # remains. Reading "newest published" would measure an image nothing boots.
    it "follows the platform pointer, not the newest published row" do
      create(:system_disk_image_publication, account: account, node_platform: platform,
             git_sha: active_sha, status: "published", published_at: 3.weeks.ago)
      create(:system_disk_image_publication, account: account, node_platform: platform,
             git_sha: head_sha, status: "published", published_at: 1.day.ago)

      signals

      expect(git_client).to have_received(:compare_commits)
        .with("powernode", "powernode-system", active_sha, head_sha)
    end
  end

  describe "a platform with no image promoted yet" do
    it "emits nothing — that is a different fact and not this sensor's" do
      platform.update!(disk_image_git_sha: nil)

      expect(signals).to be_empty
    end
  end

  describe "more than one platform" do
    it "answers each one independently" do
      platform
      current = create(:system_node_platform, account: account, disk_image_git_sha: head_sha)

      emitted = signals

      expect(emitted.map { |s| s.payload["platform_id"] }).to contain_exactly(platform.id)
      expect(emitted.map { |s| s.payload["platform_id"] }).not_to include(current.id)
    end

    it "ignores disabled platforms" do
      platform.update!(enabled: false)

      expect(signals).to be_empty
    end
  end

  # THE FINDING APPLIED TO ITSELF. Every path that cannot reach a verdict must
  # say so; silence here would reproduce the nineteen-day green-while-broken
  # window through a typo in a setting.
  describe "when the question cannot be answered" do
    it "reports not_measured when no source repository is configured" do
      SiteSetting.find_by(key: "system.disk_image.source_repo")&.destroy!

      emitted = signals
      expect(emitted.map(&:kind)).to eq([ "system.boot_image_staleness_not_measured" ])
      expect(emitted.first.payload["reason"]).to eq("source_repository_unset")
      expect(::Devops::Git::ApiClient).not_to have_received(:for)
    end

    it "reports not_measured for a non-Gitea provider rather than answering wrongly" do
      # GitHub and GitLab clients ACCEPT the path option and discard it,
      # answering with the branch tip — a well-formed answer to a different
      # question, which would make this sensor emit on every commit forever.
      provider.update!(provider_type: "github")

      emitted = signals
      expect(emitted.map(&:kind)).to eq([ "system.boot_image_staleness_not_measured" ])
      expect(emitted.first.payload["reason"]).to eq("no_usable_git_client")
    end

    it "reports not_measured when the head lookup fails" do
      allow(git_client).to receive(:list_commits).and_raise(StandardError, "gitea unreachable")

      emitted = signals
      expect(emitted.map(&:kind)).to eq([ "system.boot_image_staleness_not_measured" ])
      expect(emitted.first.payload["reason"]).to eq("head_lookup_failed")
    end

    # The comparison IS the oracle here, so a failed compare must not be read
    # as "nothing between" — that would report a stale image as current.
    it "reports not_measured when the comparison fails, never 'current'" do
      allow(git_client).to receive(:compare_commits).and_raise(StandardError, "compare failed")

      emitted = signals
      expect(emitted.map(&:kind)).to eq([ "system.boot_image_staleness_not_measured" ])
      expect(emitted.first.payload["reason"]).to eq("compare_failed")
    end

    it "never raises out of the sense pass" do
      allow(::Devops::Git::ApiClient).to receive(:for).and_raise(StandardError, "boom")

      expect { signals }.not_to raise_error
    end
  end

  describe "the check interval" do
    it "declares a tunable interval, so the pass is not making HTTP calls every tick" do
      expect(described_class.default_thresholds).to include("check_interval_seconds")
    end

    it "does not re-ask git within the interval" do
      signals
      expect(git_client).to have_received(:list_commits).twice # one per default path

      signals
      expect(git_client).to have_received(:list_commits).twice # unchanged
    end
  end

  # Read-side only, and this is the INV-1 property rather than a style point:
  # a sensor that could roll an image would be the control plane re-imaging the
  # substrate it runs on.
  describe "the autonomy binding" do
    it "binds both kinds observation-only, with no executor" do
      %w[system.boot_image_stale system.boot_image_staleness_not_measured].each do |kind|
        binding = ::System::Fleet::DecisionEngine::SIGNAL_BINDINGS.fetch(kind)
        expect(binding[:skill]).to be_nil
        expect(binding[:action_category]).to eq("system.observation")
      end
    end

    # The structural half of the safety claim: even an operator who made
    # system.observation auto_approve would find nothing to run.
    it "has no remediation applier for either kind" do
      appliers = ::System::Fleet::DecisionEngine::REMEDIATION_APPLIERS
      expect(appliers).not_to have_key("system.boot_image_stale")
      expect(appliers).not_to have_key("system.boot_image_staleness_not_measured")
    end

    it "is registered in the fleet sense pass" do
      expect(::System::Fleet::FleetAutonomyService::SENSORS).to include(described_class)
    end
  end
end
