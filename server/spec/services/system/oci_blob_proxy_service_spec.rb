# frozen_string_literal: true

require "rails_helper"
require "webmock/rspec"
require "digest"

# Focused regression spec for the pull-by-digest path. The manifest
# path (legacy) is exercised in production every day; this spec locks
# in the new digest-skip behavior so a future refactor doesn't silently
# re-introduce the tag-republish race.
RSpec.describe System::OciBlobProxyService do
  let(:account) { create(:account) }
  let(:cache_root) { Dir.mktmpdir("oci-cache") }
  let(:payload) { "fake erofs blob content; reproducible bytes." }
  let(:digest_hex) { Digest::SHA256.hexdigest(payload) }
  let(:digest_full) { "sha256:#{digest_hex}" }
  let(:oci_ref) { "git.example.org/powernode/test-module:c71ebc3" }

  before do
    stub_const("System::OciBlobProxyService::CACHE_ROOT", cache_root)
    # basic_auth!'s credential machinery (VaultCredential, Gitea
    # username discovery, etc.) is orthogonal to the digest-mode
    # behavior we're testing — stub it out at the boundary so the
    # spec stays focused on pull-by-digest.
    allow_any_instance_of(described_class).
      to receive(:basic_auth!).and_return("Basic dGVzdDp0ZXN0")
  end

  after { FileUtils.rm_rf(cache_root) }

  describe "#fetch_blob! (digest mode)" do
    it "pulls /v2/<repo>/blobs/<digest> directly, no manifest fetch" do
      blob_stub = stub_request(:get,
                               "https://git.example.org/v2/powernode/test-module/blobs/#{digest_full}").
                  to_return(status: 200,
                            body: payload,
                            headers: { "Content-Length" => payload.bytesize.to_s })

      service = described_class.new(
        oci_ref:    oci_ref,
        media_type: "application/vnd.powernode.erofs",
        digest:     digest_full,
        size:       payload.bytesize,
        account:    account
      )

      path = service.fetch_blob!
      expect(File.read(path)).to eq(payload)
      expect(blob_stub).to have_been_requested

      # Critical assertion: NO manifest fetch happened. This is the
      # entire point of digest mode — eliminate the manifest round-trip
      # that races against tag republish.
      expect(WebMock).not_to have_requested(:get,
        %r{https://git\.example\.org/v2/powernode/test-module/manifests/})
    end

    it "tolerates the input digest without sha256: prefix" do
      stub_request(:get,
                   "https://git.example.org/v2/powernode/test-module/blobs/#{digest_full}").
        to_return(status: 200, body: payload,
                  headers: { "Content-Length" => payload.bytesize.to_s })

      service = described_class.new(
        oci_ref:    oci_ref,
        media_type: "application/vnd.powernode.erofs",
        digest:     digest_hex, # bare hex, no prefix
        size:       payload.bytesize,
        account:    account
      )
      expect(File.read(service.fetch_blob!)).to eq(payload)
    end

    it "succeeds when size: is nil and trusts the sha256 verification" do
      stub_request(:get,
                   "https://git.example.org/v2/powernode/test-module/blobs/#{digest_full}").
        to_return(status: 200, body: payload)

      service = described_class.new(
        oci_ref:    oci_ref,
        media_type: "application/vnd.powernode.erofs",
        digest:     digest_full,
        # size: intentionally omitted
        account: account
      )
      expect(File.read(service.fetch_blob!)).to eq(payload)
    end

    it "raises VerificationError when the blob bytes don't hash to digest" do
      stub_request(:get,
                   "https://git.example.org/v2/powernode/test-module/blobs/#{digest_full}").
        to_return(status: 200, body: "wrong bytes",
                  headers: { "Content-Length" => "11" })

      service = described_class.new(
        oci_ref:    oci_ref,
        media_type: "application/vnd.powernode.erofs",
        digest:     digest_full,
        account:    account
      )
      expect { service.fetch_blob! }.to raise_error(System::OciBlobProxyService::VerificationError, /digest mismatch/)
      # Tmp file must be cleaned up; cache_root should be empty (or have only the lock).
      remaining = Dir.children(cache_root).reject { |f| f.end_with?(".lock") }
      expect(remaining).to be_empty
    end

    it "caches the blob by digest across calls (zero-network on second hit)" do
      blob_stub = stub_request(:get,
                               "https://git.example.org/v2/powernode/test-module/blobs/#{digest_full}").
                  to_return(status: 200, body: payload,
                            headers: { "Content-Length" => payload.bytesize.to_s })

      service = described_class.new(
        oci_ref:    oci_ref,
        media_type: "application/vnd.powernode.erofs",
        digest:     digest_full,
        size:       payload.bytesize,
        account:    account
      )
      service.fetch_blob!
      service.fetch_blob!
      service.fetch_blob!

      expect(blob_stub).to have_been_requested.once
    end
  end
end
