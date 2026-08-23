# frozen_string_literal: true

require "rails_helper"

# IMP-dc7afcbea38e: TopologyCompiler's header comment used to document
#   private_key_ref: { peer_key_id: "<uuid>" }   # agent fetches via key_distributor
# — a fetch path that has never existed. Sdwan::KeyDistributor only
# generates and rotates keys (generate_and_store!/rotate!); the private key
# actually reaches the agent by being INLINED into the node-API config
# response (TopologyCompiler#interface_block, gated on include_private_key —
# see app/controllers/api/v1/system/node_api/sdwan_controller.rb). Nothing
# else enforced that the header's claims track reality, and a stale claim
# like the one this replaces is exactly the kind of thing that misleads the
# next implementer into building against a mechanism that isn't there.
#
# This guard fails loudly on drift in either direction:
#   - the header re-describing a fetch path for the private key, or
#   - KeyDistributor growing an actual fetch/read-back method, which would
#     make the header's "no way to read one back" claim false.
RSpec.describe "TopologyCompiler header vs KeyDistributor's real interface (no fetch-path drift)" do
  let(:source_path) do
    File.expand_path("../../../app/services/sdwan/topology_compiler.rb", __dir__)
  end

  let(:header) do
    File.read(source_path).lines.take(40).join
  end

  # Matches the exact stale phrasing this fix removed, plus generic
  # paraphrases of "the agent fetches the private key [from somewhere]".
  FETCH_KEY_CLAIM_RE = /fetch(?:es)?\s+via\s+key_distributor|fetch(?:es)?\s+(?:the\s+)?(?:private\s+)?key\b/i

  it "locates a parseable header comment block documenting private_key_ref" do
    expect(File).to exist(source_path)
    expect(header).to match(/private_key_ref/)
  end

  it "does not claim the agent fetches its private key (no fetch path exists)" do
    expect(header).not_to match(FETCH_KEY_CLAIM_RE)
  end

  it "KeyDistributor exposes no fetch/read-back method, matching what the header claims" do
    fetch_like = Sdwan::KeyDistributor.singleton_methods(false).select do |m|
      m.to_s.match?(/fetch|read|retrieve/i)
    end

    expect(fetch_like).to(
      be_empty,
      "KeyDistributor grew fetch-style method(s) #{fetch_like.inspect} — " \
      "topology_compiler.rb's header must be updated, since it currently " \
      "claims KeyDistributor exposes no way to read a key back."
    )
  end
end
