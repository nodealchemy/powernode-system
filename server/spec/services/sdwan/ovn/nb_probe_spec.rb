# frozen_string_literal: true

require "rails_helper"

# IMP-57e9a90598ee — the control-plane half of the OVN activation oracle.
#
# The probe speaks OVSDB's list_dbs JSON-RPC (RFC 7047 §4.1.1) at the
# operator-asserted nb_db_endpoint. Its Result is three-valued on purpose:
# :confirmed and :failed are MEASURED verdicts, :not_measured is the explicit
# "we could not look" — and there is deliberately no predicate that collapses
# the last two, because "couldn't look" must never be read as either health or
# failure.
RSpec.describe Sdwan::Ovn::NbProbe do
  describe "Result" do
    it "rejects unknown states" do
      expect { described_class::Result.new(state: :healthy) }.to raise_error(ArgumentError)
    end

    it "keeps the three verdicts distinct" do
      expect(described_class::Result.confirmed(databases: %w[OVN_Northbound])).to be_confirmed
      expect(described_class::Result.failed(error: "x")).to be_failed
      expect(described_class::Result.not_measured(reason: "y")).to be_not_measured
    end
  end

  describe ".probe — endpoints it cannot measure" do
    it "returns not_measured for a blank endpoint" do
      expect(described_class.probe(nil)).to be_not_measured
      expect(described_class.probe("")).to be_not_measured
    end

    it "returns not_measured for ssl: endpoints — no client cert, so a failure would be meaningless" do
      result = described_class.probe("ssl:10.0.0.1:6641")
      expect(result).to be_not_measured
      expect(result.reason).to eq("tls_probe_unsupported")
    end

    it "returns not_measured for unix: endpoints" do
      expect(described_class.probe("unix:/run/ovn/ovnnb_db.sock")).to be_not_measured
    end

    it "returns not_measured for an unparseable endpoint" do
      expect(described_class.probe("tcp:not an endpoint")).to be_not_measured
    end
  end

  describe ".parse_endpoint" do
    it "parses tcp host:port" do
      expect(described_class.parse_endpoint("tcp:10.0.0.1:6641")).to eq([ "10.0.0.1", 6641 ])
    end

    it "parses a bracketed IPv6 literal" do
      expect(described_class.parse_endpoint("tcp:[fd00::1]:6641")).to eq([ "fd00::1", 6641 ])
    end

    it "probes the first member of a cluster list" do
      expect(described_class.parse_endpoint("tcp:10.0.0.1:6641,tcp:10.0.0.2:6641"))
        .to eq([ "10.0.0.1", 6641 ])
    end

    it "returns nil on garbage" do
      expect(described_class.parse_endpoint("tcp:::::")).to be_nil
    end
  end

  describe ".probe — target denial" do
    it "refuses a loopback target without opening a socket — refusal is not a measurement" do
      expect(Socket).not_to receive(:tcp)

      result = described_class.probe("tcp:127.0.0.1:6641")

      expect(result).to be_not_measured
      expect(result.reason).to eq("endpoint_target_denied")
    end

    it "refuses link-local targets" do
      expect(described_class.probe("tcp:169.254.1.1:6641")).to be_not_measured
      expect(described_class.probe("tcp:[fe80::1]:6641")).to be_not_measured
    end

    it "refuses a hostname that resolves into a denied range" do
      allow(Addrinfo).to receive(:getaddrinfo).with("nb.example.internal", 6641, nil, :STREAM)
        .and_return([ Addrinfo.tcp("10.9.9.9", 6641), Addrinfo.tcp("127.0.0.1", 6641) ])

      result = described_class.probe("tcp:nb.example.internal:6641")

      expect(result).to be_not_measured
      expect(result.reason).to eq("endpoint_target_denied")
    end

    it "honors the operator's control-plane CIDR denylist" do
      allow(::SiteSetting).to receive(:get).and_call_original
      allow(::SiteSetting).to receive(:get)
        .with("system.sdwan.ovn.probe_denied_cidrs").and_return("10.125.0.0/16, 192.0.2.0/24")

      expect(described_class.probe("tcp:10.125.0.227:6641")).to be_not_measured
      expect(described_class.probe("tcp:192.0.2.7:6641")).to be_not_measured
    end
  end

  describe ".probe — against a live socket" do
    # The fakes bind loopback, which production denies — so these pass an
    # empty denylist to exercise the OVSDB exchange itself.
    def with_fake_ovsdb(reply_body)
      server = TCPServer.new("127.0.0.1", 0)
      port = server.addr[1]
      thread = Thread.new do
        client = server.accept
        client.read_nonblock(64 * 1024, exception: false)
        client.write(reply_body)
        client.close
      rescue StandardError
        nil
      end
      yield port
    ensure
      thread&.kill
      server&.close
    end

    it "confirms when the answering server hosts OVN_Northbound" do
      reply = { id: "powernode-nb-probe", result: %w[_Server OVN_Northbound], error: nil }.to_json
      with_fake_ovsdb(reply) do |port|
        result = described_class.probe("tcp:127.0.0.1:#{port}", timeout: 2, denied_networks: [])
        expect(result).to be_confirmed
        expect(result.databases).to include("OVN_Northbound")
      end
    end

    it "fails — measured — when the server answers OVSDB but does not host OVN_Northbound" do
      reply = { id: "powernode-nb-probe", result: %w[_Server Open_vSwitch], error: nil }.to_json
      with_fake_ovsdb(reply) do |port|
        result = described_class.probe("tcp:127.0.0.1:#{port}", timeout: 2, denied_networks: [])
        expect(result).to be_failed
        expect(result.error).to include("OVN_Northbound")
      end
    end

    it "fails — measured — on a connection refusal" do
      closed = TCPServer.new("127.0.0.1", 0)
      port = closed.addr[1]
      closed.close

      result = described_class.probe("tcp:127.0.0.1:#{port}", timeout: 1, denied_networks: [])
      expect(result).to be_failed
    end

    it "fails — measured — on a garbage reply" do
      with_fake_ovsdb("definitely not json{{{") do |port|
        result = described_class.probe("tcp:127.0.0.1:#{port}", timeout: 1, denied_networks: [])
        expect(result).to be_failed
      end
    end
  end

  describe ".probe_cached" do
    let(:account)     { create(:account) }
    let!(:deployment) { create(:sdwan_ovn_deployment, account: account, status: "active") }

    around do |example|
      original = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
      example.run
    ensure
      Rails.cache = original
    end

    it "probes once per interval per deployment — the cache stores, it never verdicts" do
      expect(described_class).to receive(:probe).once
        .and_return(described_class::Result.confirmed(databases: %w[OVN_Northbound]))

      first  = described_class.probe_cached(deployment)
      second = described_class.probe_cached(deployment)

      expect(first).to be_confirmed
      expect(second).to be_confirmed
    end

    it "keys the cache on the endpoint, so an endpoint edit re-probes" do
      expect(described_class).to receive(:probe).twice
        .and_return(described_class::Result.failed(error: "refused"))

      described_class.probe_cached(deployment)
      deployment.update_columns(nb_db_endpoint: "tcp:10.9.9.9:6641")
      described_class.probe_cached(deployment)
    end
  end
end
