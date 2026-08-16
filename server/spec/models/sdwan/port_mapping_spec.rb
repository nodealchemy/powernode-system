# frozen_string_literal: true

require "rails_helper"
require_relative "support/line_safe_name_shared_examples"

RSpec.describe Sdwan::PortMapping, type: :model do
  # The :sdwan_port_mapping factory is not coherent under the `build`
  # strategy (its peers get created on a separately-minted network), so the
  # shared examples get a builder wired to this spec's own network/peers.
  it_behaves_like "a line-safe named model", :sdwan_port_mapping do
    let(:build_named) do
      ->(name) do
        described_class.new(account_id: account.id, sdwan_network_id: network.id,
                            sdwan_peer_id: hub.id, target_peer_id: target.id,
                            name: name, listen_port: 15_432, protocol: "tcp")
      end
    end
  end

  let(:account) { Account.first || create(:account) }

  before do
    Sdwan::PortMapping.where(account_id: account.id).delete_all
    Sdwan::Network.where(account_id: account.id).delete_all
    Sdwan::Configuration.where(account_id: account.id).delete_all
  end

  let!(:network) { Sdwan::Network.create!(account_id: account.id, name: "pm-net-#{SecureRandom.hex(3)}") }
  let!(:node) { sdwan_test_node(account: account) }
  let!(:inst1) { sdwan_test_node_instance(node: node) }
  let!(:inst2) { sdwan_test_node_instance(node: node) }
  let!(:hub) do
    Sdwan::Peer.create!(account: account, sdwan_network_id: network.id, node_instance: inst1,
                        publicly_reachable: true, endpoint_host_v6: "2001:db8::1", endpoint_port: 51820)
  end
  let!(:target) do
    Sdwan::Peer.create!(account: account, sdwan_network_id: network.id, node_instance: inst2,
                        publicly_reachable: false)
  end

  describe "validations" do
    it "rejects mapping with neither target_peer nor target_virtual_ip set" do
      m = described_class.new(account_id: account.id, sdwan_network_id: network.id,
                              sdwan_peer_id: hub.id, name: "no-target",
                              listen_port: 5432, protocol: "tcp")
      expect(m).not_to be_valid
      expect(m.errors[:base].join).to match(/exactly one of target_peer_id or target_virtual_ip_id/)
    end

    it "rejects mapping with both targets set" do
      vip = Sdwan::VirtualIp.create!(account_id: account.id, sdwan_network_id: network.id,
                                     name: "vip-#{SecureRandom.hex(2)}", cidr: "192.0.2.50/32",
                                     holder_peer_ids: [ target.id ], state: "active")
      m = described_class.new(account_id: account.id, sdwan_network_id: network.id,
                              sdwan_peer_id: hub.id, target_peer_id: target.id,
                              target_virtual_ip_id: vip.id, name: "double",
                              listen_port: 5432, protocol: "tcp")
      expect(m).not_to be_valid
      expect(m.errors[:base].join).to match(/exactly one/)
    end

    it "enforces (hub, listen_port, protocol) uniqueness" do
      described_class.create!(account_id: account.id, sdwan_network_id: network.id,
                              sdwan_peer_id: hub.id, target_peer_id: target.id,
                              name: "first", listen_port: 5432, protocol: "tcp")
      dupe = described_class.new(account_id: account.id, sdwan_network_id: network.id,
                                 sdwan_peer_id: hub.id, target_peer_id: target.id,
                                 name: "dupe", listen_port: 5432, protocol: "tcp")
      expect(dupe).not_to be_valid
      expect(dupe.errors[:sdwan_peer_id]).to include("has already been taken")
    end

    it "allows different protocols on the same (hub, listen_port)" do
      described_class.create!(account_id: account.id, sdwan_network_id: network.id,
                              sdwan_peer_id: hub.id, target_peer_id: target.id,
                              name: "tcp-svc", listen_port: 5432, protocol: "tcp")
      udp = described_class.new(account_id: account.id, sdwan_network_id: network.id,
                                sdwan_peer_id: hub.id, target_peer_id: target.id,
                                name: "udp-svc", listen_port: 5432, protocol: "udp")
      expect(udp).to be_valid
    end

    it "rejects targets in a different network" do
      other_net = Sdwan::Network.create!(account_id: account.id, name: "other-pm-#{SecureRandom.hex(3)}")
      foreign = Sdwan::Peer.create!(account: account, sdwan_network_id: other_net.id,
                                    node_instance: inst2, publicly_reachable: false)
      m = described_class.new(account_id: account.id, sdwan_network_id: network.id,
                              sdwan_peer_id: hub.id, target_peer_id: foreign.id,
                              name: "cross-net", listen_port: 5432, protocol: "tcp")
      expect(m).not_to be_valid
      expect(m.errors[:target_peer_id].join).to match(/same network/)
    end
  end

  describe "#effective_target_port" do
    it "returns target_port when set" do
      m = described_class.new(listen_port: 5432, target_port: 6432)
      expect(m.effective_target_port).to eq(6432)
    end

    it "falls back to listen_port when target_port is nil" do
      m = described_class.new(listen_port: 5432, target_port: nil)
      expect(m.effective_target_port).to eq(5432)
    end
  end

  describe "#resolved_target_address" do
    it "strips the /128 suffix from the target peer's overlay address" do
      m = described_class.create!(account_id: account.id, sdwan_network_id: network.id,
                                  sdwan_peer_id: hub.id, target_peer_id: target.id,
                                  name: "addr-test", listen_port: 22, protocol: "tcp")
      expect(m.resolved_target_address).to eq(target.assigned_address.split("/").first)
    end
  end

  # ─── Campaign 019f3458 increment 6: hardened DNAT tier ─────────────────

  describe "rate_limit validation" do
    def build_mapping(rate_limit:)
      described_class.new(account_id: account.id, sdwan_network_id: network.id,
                         sdwan_peer_id: hub.id, target_peer_id: target.id,
                         name: "rl-#{SecureRandom.hex(2)}", listen_port: 8080, protocol: "tcp",
                         rate_limit: rate_limit)
    end

    it "allows nil (unrestricted)" do
      expect(build_mapping(rate_limit: nil)).to be_valid
    end

    it "allows a positive integer" do
      expect(build_mapping(rate_limit: 100)).to be_valid
    end

    it "rejects zero" do
      m = build_mapping(rate_limit: 0)
      expect(m).not_to be_valid
      expect(m.errors[:rate_limit].join).to match(/greater than 0/)
    end

    it "rejects a negative value" do
      m = build_mapping(rate_limit: -5)
      expect(m).not_to be_valid
      expect(m.errors[:rate_limit].join).to match(/greater than 0/)
    end

    it "rejects a non-integer value" do
      m = build_mapping(rate_limit: 1.5)
      expect(m).not_to be_valid
      expect(m.errors[:rate_limit].join).to match(/must be an integer/)
    end
  end

  describe "max_connections validation" do
    def build_mapping(max_connections:)
      described_class.new(account_id: account.id, sdwan_network_id: network.id,
                         sdwan_peer_id: hub.id, target_peer_id: target.id,
                         name: "mc-#{SecureRandom.hex(2)}", listen_port: 8081, protocol: "tcp",
                         max_connections: max_connections)
    end

    it "allows nil (unrestricted)" do
      expect(build_mapping(max_connections: nil)).to be_valid
    end

    it "allows a positive integer" do
      expect(build_mapping(max_connections: 50)).to be_valid
    end

    it "rejects zero" do
      m = build_mapping(max_connections: 0)
      expect(m).not_to be_valid
      expect(m.errors[:max_connections].join).to match(/greater than 0/)
    end

    it "rejects a negative value" do
      m = build_mapping(max_connections: -1)
      expect(m).not_to be_valid
      expect(m.errors[:max_connections].join).to match(/greater than 0/)
    end
  end

  describe "source_cidrs validation" do
    def build_mapping(source_cidrs:)
      described_class.new(account_id: account.id, sdwan_network_id: network.id,
                         sdwan_peer_id: hub.id, target_peer_id: target.id,
                         name: "cidr-#{SecureRandom.hex(2)}", listen_port: 8082, protocol: "tcp",
                         source_cidrs: source_cidrs)
    end

    it "defaults to an empty array (unrestricted)" do
      m = described_class.new(account_id: account.id, sdwan_network_id: network.id,
                              sdwan_peer_id: hub.id, target_peer_id: target.id,
                              name: "cidr-default", listen_port: 8083, protocol: "tcp")
      expect(m.source_cidrs).to eq([])
      expect(m).to be_valid
    end

    it "accepts a valid v4 CIDR" do
      expect(build_mapping(source_cidrs: [ "203.0.113.0/24" ])).to be_valid
    end

    it "accepts a valid v6 CIDR" do
      expect(build_mapping(source_cidrs: [ "2001:db8::/32" ])).to be_valid
    end

    it "accepts a mix of v4 and v6 entries" do
      expect(build_mapping(source_cidrs: [ "203.0.113.0/24", "2001:db8::/32" ])).to be_valid
    end

    it "rejects a malformed entry with a clear per-entry message" do
      m = build_mapping(source_cidrs: [ "not-a-cidr" ])
      expect(m).not_to be_valid
      expect(m.errors[:source_cidrs].join).to match(/invalid CIDR entry.*"not-a-cidr"/)
    end

    it "rejects an out-of-range prefix length" do
      m = build_mapping(source_cidrs: [ "10.0.0.0/33" ])
      expect(m).not_to be_valid
      expect(m.errors[:source_cidrs].join).to match(/invalid CIDR entry/)
    end

    it "reports one error per invalid entry" do
      m = build_mapping(source_cidrs: [ "bad-one", "also-bad" ])
      expect(m).not_to be_valid
      expect(m.errors[:source_cidrs].size).to eq(2)
    end

    it "rejects a non-array value" do
      m = build_mapping(source_cidrs: "203.0.113.0/24")
      expect(m).not_to be_valid
      expect(m.errors[:source_cidrs].join).to match(/must be an array/)
    end
  end

  describe "#source_cidrs_by_family" do
    def build_mapping(source_cidrs:)
      described_class.new(account_id: account.id, sdwan_network_id: network.id,
                         sdwan_peer_id: hub.id, target_peer_id: target.id,
                         name: "fam-#{SecureRandom.hex(2)}", listen_port: 8084, protocol: "tcp",
                         source_cidrs: source_cidrs)
    end

    it "returns empty v4/v6 arrays when source_cidrs is empty" do
      expect(build_mapping(source_cidrs: []).source_cidrs_by_family).to eq(v4: [], v6: [])
    end

    it "splits mixed entries by family" do
      m = build_mapping(source_cidrs: [ "203.0.113.0/24", "2001:db8::/32", "198.51.100.5" ])
      result = m.source_cidrs_by_family
      expect(result[:v4]).to contain_exactly("203.0.113.0/24", "198.51.100.5")
      expect(result[:v6]).to contain_exactly("2001:db8::/32")
    end
  end

  # ─── IMP-2c531ddb5a0c: the writable list is the seam, this is its floor ──
  #
  # WRITABLE_ATTRIBUTES makes the two surfaces agree by construction, which
  # answers "did one of them drift from the other" but not "did a new column
  # land outside BOTH of them" — an ADDITION no mutation of either permit list
  # can produce. So every column is classified exactly once, here.
  #
  # NON_WRITABLE is a pinned intent list, not a rule: adding a column to it is
  # a one-line, deliberate, reviewable act, whereas a blanket "these shapes are
  # never writable" heuristic would eventually forbid a column someone has a
  # good reason to permit. Each entry below records WHY it is not caller-input.
  describe "writable attribute classification" do
    # A `let`, not a constant: a bare assignment inside a describe block binds
    # on Object (blocks carry no lexical scope of their own), which is how one
    # spec file's list clobbers another's.
    let(:non_writable_columns) do
      {
        "id" => "UUIDv7 primary key",
        "account_id" => "tenancy — CreatePortMapping takes it from the resolved network, " \
                        "and System::Executors::Base strips it from every replayed attrs hash",
        "sdwan_network_id" => "the parent; a create resolves it from the route/params and an " \
                              "update anchors it through Base#anchor_reparent!",
        "last_compiled_at" => "written by Sdwan::NatCompiler, never by a caller",
        "created_at" => "Rails timestamp",
        "updated_at" => "Rails timestamp"
      }.freeze
    end

    it "classifies every column as either caller-writable or deliberately not" do
      writable = described_class::WRITABLE_ATTRIBUTES.map(&:to_s)
      unclassified = described_class.column_names - writable - non_writable_columns.keys

      expect(unclassified).to be_empty,
                              "columns reachable from no surface and recorded as non-writable nowhere: " \
                              "#{unclassified.join(', ')}. Add each to Sdwan::PortMapping::" \
                              "WRITABLE_SCALAR_ATTRIBUTES / WRITABLE_STRUCTURED_ATTRIBUTES (both " \
                              "surfaces then accept it) or to non_writable_columns above with a reason."
    end

    it "never lets a non-writable column into the writable list" do
      overlap = described_class::WRITABLE_ATTRIBUTES.map(&:to_s) & non_writable_columns.keys

      expect(overlap).to be_empty,
                         "these are mass-assignable from both surfaces but recorded as non-caller-input: " \
                         "#{overlap.join(', ')}"
    end

    it "names only real columns" do
      expect(described_class::WRITABLE_ATTRIBUTES.map(&:to_s) - described_class.column_names).to be_empty
      expect(non_writable_columns.keys - described_class.column_names).to be_empty
    end

    # The scalar/structured split exists so strong parameters gets each
    # non-scalar's shape; a symbol that drifts between the two halves silently
    # changes what REST accepts.
    it "keeps the two halves disjoint and jointly equal to the whole" do
      scalar     = described_class::WRITABLE_SCALAR_ATTRIBUTES
      structured = described_class::WRITABLE_STRUCTURED_ATTRIBUTES.keys

      expect(scalar & structured).to be_empty
      expect(described_class::WRITABLE_ATTRIBUTES).to match_array(scalar + structured)
    end
  end
end
