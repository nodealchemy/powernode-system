# frozen_string_literal: true

require "rails_helper"

# Two defects found 2026-07-29 while diagnosing why an ops-cell boot-image
# upgrade returned 500:
#
#   1. CACHE_ROOT defaulted to /var/lib/powernode/oci-cache, which on a pivot
#      node is the EPHEMERAL composed overlay. After ops-hub rebooted the
#      directory did not exist at all — so the "first request per digest caches
#      for the rest of the fleet" property only ever held WITHIN one boot, and
#      every reboot reset fleet-wide registry dependence to zero-cached.
#
#   2. fetch_blob! rescued StandardError only to emit an event and re-`raise`
#      the ORIGINAL exception. BootImageController rescues PullError to return
#      502 (honest: "upstream failed, retry"), but a raw Net::OpenTimeout sails
#      past it and becomes a 500 — which reads as a platform defect and is
#      exactly how the outage was misdiagnosed.
RSpec.describe System::OciBlobProxyService do
  describe "cache durability" do
    # The constant is frozen at load, so assert the RESOLVER that computes it
    # rather than trying to reload the class under a stubbed ENV.
    it "prefers the durable partition when the host has one" do
      allow(File).to receive(:directory?).and_call_original
      allow(File).to receive(:directory?).with("/persist").and_return(true)

      expect(described_class.default_cache_root).to start_with("/persist/")
    end

    it "falls back to /var/lib on a host with no /persist" do
      allow(File).to receive(:directory?).and_call_original
      allow(File).to receive(:directory?).with("/persist").and_return(false)

      expect(described_class.default_cache_root).to eq("/var/lib/powernode/oci-cache")
    end

    it "always lets an explicit env override win" do
      expect(described_class.default_cache_root("/custom/cache")).to eq("/custom/cache")
    end
  end

  describe "error wrapping" do
    subject(:svc) do
      described_class.new(oci_ref: "example.test/repo:tag",
                          media_type: "application/vnd.powernode.uki.v1",
                          digest: "sha256:#{'a' * 64}",
                          account: account)
    end
    let(:account) { create(:account) }

    # The specific failure: DNS/connect timeouts to the registry must present
    # as an upstream fault, not a platform fault.
    it "wraps a network timeout as PullError so callers can answer 502" do
      allow(svc).to receive(:resolve_digest_and_size!).and_raise(Net::OpenTimeout)

      expect { svc.fetch_blob! }.to raise_error(described_class::PullError, /timed out|OpenTimeout/i)
    end

    it "wraps a generic StandardError as PullError too" do
      allow(svc).to receive(:resolve_digest_and_size!).and_raise(StandardError, "boom")

      expect { svc.fetch_blob! }.to raise_error(described_class::PullError, /boom/)
    end

    # Subclasses already carry precise meaning (auth vs manifest vs
    # verification); re-wrapping them would flatten that distinction.
    it "passes an existing PullError subclass through unchanged" do
      allow(svc).to receive(:resolve_digest_and_size!)
        .and_raise(described_class::AuthError, "denied")

      expect { svc.fetch_blob! }.to raise_error(described_class::AuthError, /denied/)
    end
  end
end
