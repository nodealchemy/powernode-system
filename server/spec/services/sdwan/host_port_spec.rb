# frozen_string_literal: true

require "rails_helper"

# IMP-9537a74e50fa — the one implementation of the bracket-v6 "host:port"
# expression. Six sites hand-rolled it before this existed; three of them
# omitted the already-bracketed guard and emitted "[[fd00::1]]:4739".
RSpec.describe Sdwan::HostPort do
  describe ".join" do
    it "leaves an IPv4 literal unbracketed" do
      expect(described_class.join("10.0.0.1", 4739)).to eq("10.0.0.1:4739")
    end

    it "leaves a hostname unbracketed" do
      expect(described_class.join("edge.example.net", 51_820)).to eq("edge.example.net:51820")
    end

    it "brackets an IPv6 literal so the colon does not collide with the port separator" do
      expect(described_class.join("fd00::1", 4739)).to eq("[fd00::1]:4739")
    end

    it "does not double-bracket a host that already carries brackets" do
      expect(described_class.join("[fd00::1]", 4739)).to eq("[fd00::1]:4739")
    end

    it "pins the pre-existing nil behaviour: coerce, do not guard" do
      # Not a desirable output — it is what all six call sites already did via
      # `host.to_s`, and every producer blocks it upstream (Sdwan::Service's
      # backend_present validation, Sdwan::IpfixCollector's `presence: true`).
      # Pinned so a future blank-guard is a deliberate change, not a surprise.
      expect(described_class.join(nil, 4739)).to eq(":4739")
    end
  end

  # The delegation from the published Sdwan::Peer.format_host_port is pinned in
  # spec/models/sdwan/peer_spec.rb against absolute expected values. Comparing
  # the two here would be a tautology — format_host_port IS this method now.
end
