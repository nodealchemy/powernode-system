# frozen_string_literal: true

require "rails_helper"

# OciBlobProxyService is a read-through cache, so before this the FIRST node to
# upgrade always paid a cold miss — and paid it on a just-published digest,
# i.e. the one nothing had fetched yet. On 2026-07-29 a registry DNS fault
# turned that cold miss into a 500 and a failed boot-image upgrade.
#
# Warming at publish moves the registry dependency to a moment when the
# registry is known-good (CI pushed the blob seconds earlier) instead of an
# arbitrary later one.
RSpec.describe System::DiskImagePublicationProcessor, "UKI cache warm-on-publish" do
  let(:processor) { described_class.new }
  let(:account)   { create(:account) }
  let(:publication) do
    instance_double(
      System::DiskImagePublication,
      uki_oci_ref: "reg.test/disk-images/x-uki:abc",
      uki_sha256:  "sha256:#{'b' * 64}",
      account:     account
    )
  end

  def expect_proxy_built_with(ref:, digest:)
    proxy = instance_double(System::OciBlobProxyService)
    expect(System::OciBlobProxyService).to receive(:new)
      .with(hash_including(oci_ref: ref, digest: digest, account: account))
      .and_return(proxy)
    expect(proxy).to receive(:fetch_blob!)
    proxy
  end

  it "fetches the promoted UKI blob so the first node hits a warm cache" do
    expect_proxy_built_with(ref: publication.uki_oci_ref, digest: publication.uki_sha256)

    processor.send(:warm_uki_blob_cache!, publication)
  end

  # The load-bearing property. A publication is valid whether or not the cache
  # is warm — the read-through path still works — so a warm failure must never
  # fail the publish or roll the platform pointer back. Without this, adding a
  # cache optimisation would have made publishing STRICTLY more fragile.
  it "never raises when the registry is unreachable" do
    proxy = instance_double(System::OciBlobProxyService)
    allow(System::OciBlobProxyService).to receive(:new).and_return(proxy)
    allow(proxy).to receive(:fetch_blob!).and_raise(System::OciBlobProxyService::PullError, "registry down")

    expect { processor.send(:warm_uki_blob_cache!, publication) }.not_to raise_error
  end

  it "never raises on an unexpected error class either" do
    proxy = instance_double(System::OciBlobProxyService)
    allow(System::OciBlobProxyService).to receive(:new).and_return(proxy)
    allow(proxy).to receive(:fetch_blob!).and_raise(Net::OpenTimeout)

    expect { processor.send(:warm_uki_blob_cache!, publication) }.not_to raise_error
  end

  # A publication with no standalone UKI artifact is legitimate (older
  # pipelines); warming must no-op rather than construct a proxy with nils.
  it "no-ops when the publication carries no UKI artifact" do
    bare = instance_double(System::DiskImagePublication,
                           uki_oci_ref: nil, uki_sha256: nil, account: account)
    expect(System::OciBlobProxyService).not_to receive(:new)

    processor.send(:warm_uki_blob_cache!, bare)
  end

  it "no-ops when the ref is present but the digest is blank" do
    partial = instance_double(System::DiskImagePublication,
                              uki_oci_ref: "reg.test/x-uki:abc", uki_sha256: "", account: account)
    expect(System::OciBlobProxyService).not_to receive(:new)

    processor.send(:warm_uki_blob_cache!, partial)
  end
end
