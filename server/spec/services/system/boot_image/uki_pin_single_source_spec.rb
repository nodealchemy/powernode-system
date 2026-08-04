# frozen_string_literal: true

require "rails_helper"

# IMP-dbd848ce393c — the UKI pins have exactly ONE home: the publication row.
#
# NodePlatform used to carry disk_image_uki_oci_ref / disk_image_uki_sha256 as
# a mirror of the promoted publication: written by three promote-shaped paths
# (publication processor, promote executor, rollback executor) and read by
# nobody. The mirror could drift out of step with disk_image_git_sha, which is
# exactly the failure IMP-4452cb88e195 (plan + dispatch) and IMP-b55869029a57
# (download endpoint) each had to fix — a node downloading one image's UKI and
# cosign-verifying it against a different image's bundle.
#
# Deleting the columns fixes today. These examples are the durable half: they
# fail if a mirror is ever reintroduced, so it cannot quietly come back and
# start going stale again. Note the invariant is asserted by SHAPE (no
# uki-named column on the platform at all), not by the two dropped names, so a
# re-mirror under a renamed column is caught just as loudly.
RSpec.describe "UKI pin single source of truth" do
  it "keeps no UKI mirror column on system_node_platforms" do
    uki_columns = ::System::NodePlatform.column_names.grep(/uki/i)

    expect(uki_columns).to be_empty,
                           "NodePlatform must not mirror the UKI pins. They live on " \
                           "System::DiskImagePublication (uki_oci_ref / uki_sha256), which is " \
                           "what every reader resolves — a copy on the platform can go stale " \
                           "relative to disk_image_git_sha and smear a mismatched (uki, bundle) " \
                           "pair into an upgrade task. Found: #{uki_columns.inspect}"
  end

  it "keeps the UKI pins on the publication row" do
    expect(::System::DiskImagePublication.column_names)
      .to include("uki_oci_ref", "uki_sha256")
  end

  describe "promoting a publication" do
    let(:account)  { create(:account) }
    let(:platform) { create(:system_node_platform, account: account) }
    let!(:publication) do
      create(:system_disk_image_publication, :published,
             account: account, node_platform: platform,
             git_sha: "sha-promoted",
             oci_ref: "ghcr.io/nodealchemy/system/disk:sha-promoted",
             uki_oci_ref: "ghcr.io/nodealchemy/system/uki:sha-promoted",
             uki_sha256: "d" * 64)
    end

    it "advances the platform's boot pointer without mirroring the UKI pins onto it" do
      ::System::Executors::DiskImage::PromotePublication.execute(
        { "publication_id" => publication.id }, deferred_operation: nil
      )

      platform.reload

      # The non-UKI pointers ARE the platform's job — it answers "what do newly
      # provisioned nodes boot" — so this half must keep working.
      expect(platform).to have_attributes(
        disk_image_git_sha: "sha-promoted",
        disk_image_oci_ref: "ghcr.io/nodealchemy/system/disk:sha-promoted",
        disk_image_publication_status: "published"
      )

      # ...but nothing UKI-shaped may land on the platform, under any name.
      expect(platform.attributes.keys.grep(/uki/i)).to be_empty
    end
  end
end
