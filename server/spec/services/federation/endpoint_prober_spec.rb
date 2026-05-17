# frozen_string_literal: true

require "rails_helper"

RSpec.describe Federation::EndpointProber, type: :service do
  let(:account) { create(:account) }
  let(:peer)    { create(:system_federation_peer, :platform, :active, account: account) }

  let(:lan_endpoint)   { { "url" => "https://hub.lan:8443",        "scope" => "lan",   "priority" => 1 } }
  let(:sdwan_endpoint) { { "url" => "https://[fd00:abc::1]:443",   "scope" => "sdwan", "priority" => 2 } }
  let(:wan_endpoint)   { { "url" => "https://hub.example.com:443", "scope" => "wan",   "priority" => 3 } }

  before do
    peer.update!(endpoints: [ lan_endpoint, sdwan_endpoint, wan_endpoint ])
  end

  describe ".probe!" do
    context "when the first endpoint is reachable" do
      it "returns ok + that endpoint + records last_verified_at" do
        # Stub Socket.tcp to succeed on the LAN endpoint
        allow(::Socket).to receive(:tcp).with("hub.lan", 8443, connect_timeout: anything)
                                       .and_return(instance_double("TCPSocket", close: nil))

        result = described_class.probe!(peer: peer)
        expect(result.ok?).to be true
        expect(result.endpoint["url"]).to eq("https://hub.lan:8443")
        expect(peer.reload.endpoints.first["last_verified_at"]).to be_present
      end
    end

    context "when LAN fails but SDWAN succeeds" do
      it "falls through to the SDWAN endpoint" do
        allow(::Socket).to receive(:tcp).with("hub.lan", 8443, anything)
                                       .and_raise(Errno::ECONNREFUSED, "refused")
        allow(::Socket).to receive(:tcp).with("[fd00:abc::1]", 443, anything)
                                       .and_return(instance_double("TCPSocket", close: nil))

        result = described_class.probe!(peer: peer)
        expect(result.ok?).to be true
        expect(result.endpoint["scope"]).to eq("sdwan")
        expect(result.probed.size).to eq(2)
        # LAN endpoint records the failure
        lan = peer.reload.endpoints.find { |e| e["scope"] == "lan" }
        expect(lan["last_failure_at"]).to be_present
        expect(lan["last_failure_error"]).to include("ECONNREFUSED")
      end
    end

    context "when all endpoints fail" do
      it "returns ok? false + all_failed? true + records every failure" do
        allow(::Socket).to receive(:tcp).and_raise(Errno::ECONNREFUSED, "refused")

        result = described_class.probe!(peer: peer)
        expect(result.ok?).to be false
        expect(result.all_failed?).to be true
        expect(result.probed.size).to eq(3)
        expect(result.error).to match(/all 3 endpoints unreachable/)
      end
    end

    context "when timeout fires" do
      it "marks the endpoint as failed with timeout error" do
        allow(::Socket).to receive(:tcp).and_raise(Errno::ETIMEDOUT, "timeout")

        result = described_class.probe!(peer: peer)
        expect(result.ok?).to be false
        expect(result.probed.first[:error]).to include("ETIMEDOUT")
      end
    end

    context "with scope_filter" do
      it "only probes endpoints in the supplied scopes" do
        allow(::Socket).to receive(:tcp).with("[fd00:abc::1]", 443, anything)
                                       .and_return(instance_double("TCPSocket", close: nil))

        result = described_class.probe!(peer: peer, scope_filter: %w[sdwan])
        expect(result.ok?).to be true
        expect(result.endpoint["scope"]).to eq("sdwan")
        expect(result.probed.size).to eq(1)  # LAN + WAN skipped
      end

      it "returns no-endpoints error when filter matches nothing" do
        result = described_class.probe!(peer: peer, scope_filter: %w[carrier-pigeon])
        expect(result.ok?).to be false
        expect(result.error).to match(/no advertised endpoints/)
      end
    end

    context "with no endpoints advertised" do
      before { peer.update!(endpoints: []) }

      it "returns no-endpoints error immediately" do
        result = described_class.probe!(peer: peer)
        expect(result.ok?).to be false
        expect(result.error).to match(/no advertised endpoints/)
        expect(result.probed).to be_empty
      end
    end

    context "with priority ordering" do
      it "probes in ascending priority order regardless of array order" do
        peer.update!(endpoints: [ wan_endpoint, lan_endpoint, sdwan_endpoint ])
        # Even though LAN is now second in the array, priority=1 puts it first
        allow(::Socket).to receive(:tcp).with("hub.lan", 8443, anything)
                                       .and_return(instance_double("TCPSocket", close: nil))

        result = described_class.probe!(peer: peer)
        expect(result.ok?).to be true
        expect(result.endpoint["scope"]).to eq("lan")
        expect(result.probed.size).to eq(1) # LAN succeeded on first try
      end
    end

    context "with invalid endpoint entries" do
      it "ignores entries without a url" do
        peer.update!(endpoints: [ { "scope" => "lan", "priority" => 1 }, lan_endpoint ])
        allow(::Socket).to receive(:tcp).with("hub.lan", 8443, anything)
                                       .and_return(instance_double("TCPSocket", close: nil))

        result = described_class.probe!(peer: peer)
        expect(result.ok?).to be true
        expect(result.probed.size).to eq(1)
      end
    end
  end
end
