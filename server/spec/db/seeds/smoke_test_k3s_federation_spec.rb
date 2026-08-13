# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("../extensions/system/server/db/seeds/_smoke_k3s_helpers").to_s

# IMP-de7b0ec66dea — Phase 5 of the K3s lifecycle smoke drove all three
# Sdwan::Executors::*FederationPeer classes through a constructor they have
# never had (`account:`/`user:`/`agent:`/`params:`/`confirmed:`), while
# System::Executors::Base takes `(params, deferred_operation:)`. The script
# therefore raised ArgumentError at its first executor call and the smoke
# catalog counted coverage it did not deliver.
#
# The seed is a straight-line script, so this runs it — nothing about the
# federation legs is re-implemented here. Only the host-dependent parts are
# stubbed (tier gate, the 8-item preflight, the /tmp state sidecar, and the
# site+ kubectl leg, which needs a live Site B and a kubectl binary).
# Everything from "Propose federation peer" down executes for real against
# the test DB, which is what makes this red on the stale constructor.
RSpec.describe "smoke_test_k3s_federation seed (IMP-de7b0ec66dea)" do
  let(:seed_path) do
    Rails.root.join("../extensions/system/server/db/seeds/smoke_test_k3s_federation.rb").to_s
  end
  let(:helpers) { ::System::Seeds::SmokeK3sHelpers }

  let(:account)   { create(:account) }
  let!(:operator) { create(:user, account: account) }
  let(:a_cluster) { create(:devops_kubernetes_cluster, account: account) }
  let(:b_cluster) { create(:devops_kubernetes_cluster, account: account) }
  let(:a_network) { create(:sdwan_network, account: account) }
  let(:b_network) { create(:sdwan_network, account: account) }

  let(:sidecar) do
    {
      "site_a_cluster_id" => a_cluster.id,
      "site_b_cluster_id" => b_cluster.id,
      "site_a_network_id" => a_network.id,
      "site_b_network_id" => b_network.id
    }
  end

  before do
    allow(helpers).to receive(:current_tier).and_return("full")
    allow(helpers).to receive(:tier_gate).and_return("full")
    allow(helpers).to receive(:preflight!)
    allow(helpers).to receive(:discover_or_create_account!).and_return(account)
    allow(helpers).to receive(:state_read).and_return(sidecar)
    allow(helpers).to receive(:state_write)

    # The cross-site API-plane leg shells out to kubectl against a live Site B.
    allow(helpers).to receive(:tier_at_least?).with("site").and_return(false)

    # #fail_with aborts the process, which RSpec deliberately does not rescue
    # (SystemExit is in AVOID_RESCUING). Re-raise as a StandardError so a
    # failed h.assert surfaces as a spec failure instead of killing the run.
    allow(helpers).to receive(:fail_with) { |msg| raise "SMOKE FAIL: #{msg}" }
  end

  def peer
    ::System::FederationPeer.where(account: account).sole
  end

  it "proposes and accepts a federation peer through the executor contract" do
    expect { load seed_path }.not_to raise_error

    expect(peer.status).to eq("accepted")
    expect(peer.remote_instance_url).to eq("https://powernode-site-b.smoke.local")
    expect(peer.spawn_mode).to eq("autonomous_peer")
  end

  # The account the peer is created under comes from the executor's
  # `deferred_operation&.account`, so a context that does not carry it would
  # fail FederationPeer's `belongs_to :account` rather than land elsewhere.
  it "creates the peer under the smoke's account" do
    load seed_path

    expect(peer.account_id).to eq(account.id)
  end

  # ProposeFederationPeer mints an acceptance token by default, and accept!
  # refuses a peer carrying a digest unless the plaintext is presented. The
  # smoke has to carry the minted token from propose into accept; if it does
  # not, AcceptFederationPeer raises (e655659f made that refusal loud).
  it "threads the minted single-use acceptance token into the accept leg" do
    load seed_path

    expect(peer.metadata["acceptance_token_used"]).to be(true)
    expect(peer.acceptance_token_digest).to be_nil
    expect(peer.acceptance_token_expires_at).to be_nil
  end

  # accept! stamps the accepting operator from `deferred_operation&.requested_by`,
  # never from params — so this pins that the smoke's context carries a user.
  it "records the accepting operator on the peer" do
    load seed_path

    expect(peer.metadata["accepted_by_user_id"]).to eq(operator.id)
  end

  context "with the optional revoke pass enabled" do
    around do |example|
      previous = ENV["SMOKE_K3S_FEDERATION_REVOKE"]
      ENV["SMOKE_K3S_FEDERATION_REVOKE"] = "1"
      example.run
    ensure
      ENV["SMOKE_K3S_FEDERATION_REVOKE"] = previous
    end

    it "revokes the peer with an audited reason" do
      expect { load seed_path }.not_to raise_error

      expect(peer.status).to eq("revoked")
      expect(peer.metadata["revocation_reason"]).to be_present
    end
  end
end
