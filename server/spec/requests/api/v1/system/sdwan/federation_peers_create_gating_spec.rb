# frozen_string_literal: true

require "rails_helper"

# IMP-785d60f5ec3e — POST /federation_peers called the gate with raw params and
# no candidate, so an unsaveable payload was PARKED as an approval that could
# only ever fail, in front of an approver who cannot see it was doomed when it
# was submitted.
#
# The guard is a PROPERTY: an invalid payload must open no
# Ai::DeferredOperation and must answer with the SAME status whatever the
# account's intervention policy says. Ai::AutonomyGate#evaluate creates the
# DeferredOperation row BEFORE it branches on policy, so `not_to change` on
# that count proves the gate was never reached rather than merely that nothing
# happened.
RSpec.describe "Api::V1::System::Sdwan::FederationPeers create gating", type: :request do
  # Two accounts on DIFFERENT policies — see the same note in
  # instance_pools_create_gating_spec.rb. A single-policy example cannot
  # observe a verdict that tracks the policy instead of the request.
  let(:parked_account)     { create(:account) }
  let(:proceeding_account) { create(:account) }

  let(:parked_user) do
    user_with_permissions("system.sdwan.federation.read", "system.sdwan.federation.manage",
                          account: parked_account)
  end
  let(:proceeding_user) do
    user_with_permissions("system.sdwan.federation.read", "system.sdwan.federation.manage",
                          account: proceeding_account)
  end

  before do
    ::Ai::InterventionPolicy.create!(
      account: proceeding_account, ai_agent_id: nil, scope: "action_type",
      action_category: ::Sdwan::Executors::ProposeFederationPeer::ACTION_CATEGORY,
      policy: "notify_and_proceed", priority: 5, is_active: true
    )
  end

  # remote_instance_url is the SOLE invalid field: present (so it clears the
  # presence check) but not a URL (so it fails the format one). No fixture and
  # no account-scoped uniqueness is involved, which is what lets the identical
  # bytes go to both accounts.
  let(:invalid_attrs) { { remote_instance_url: "not-a-url" } }
  let(:valid_attrs)   { { remote_instance_url: "https://peer.example.test" } }

  def post_create(user, attrs)
    post "/api/v1/system/sdwan/federation_peers",
         params: { federation_peer: attrs }.to_json,
         headers: auth_headers_for(user).merge("Content-Type" => "application/json")
  end

  describe "an invalid payload" do
    it "opens no deferred operation on the account whose policy would PARK it" do
      expect { post_create(parked_user, invalid_attrs) }
        .not_to change(::Ai::DeferredOperation, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(::System::FederationPeer.where(account_id: parked_account.id).count).to eq(0)
    end

    it "opens no deferred operation on the account whose policy would PROCEED" do
      expect { post_create(proceeding_user, invalid_attrs) }
        .not_to change(::Ai::DeferredOperation, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(::System::FederationPeer.where(account_id: proceeding_account.id).count).to eq(0)
    end

    it "mints no approval request for an operation that could never run" do
      expect { post_create(parked_user, invalid_attrs) }
        .not_to change(::Ai::ApprovalRequest, :count)
    end

    it "answers the SAME status under both policies for the same payload" do
      post_create(parked_user, invalid_attrs)
      parked_status = response.status

      post_create(proceeding_user, invalid_attrs)
      proceeding_status = response.status

      expect(parked_status).to eq(proceeding_status),
                               "the same payload answered #{parked_status} under a parking policy and " \
                               "#{proceeding_status} under a proceeding one — the verdict tracked the " \
                               "account's policy, not the request"
      expect(parked_status).to eq(422)
    end

    # Run against BOTH accounts deliberately. The negative half is the one
    # that names the defect, and it only bites on the PROCEEDING account:
    # pre-fix the parked account answered 202 with no error body at all (so
    # this assertion could not fail there), while the proceeding account
    # answered 422 carrying the gate's bare "Gate evaluation failed: ..."
    # from Ai::AutonomyGate's StandardError rescue — no details.errors, and
    # nothing telling the caller which field to correct.
    it "names the field the caller has to fix, rather than the gate" do
      [ parked_user, proceeding_user ].each do |user|
        post_create(user, invalid_attrs)

        # render_error puts the message under "error" — NOT "message", which
        # it never sets. Reading only "message" made the negative assertion
        # unfailable, since the gate's refusal lands in "error" too.
        body = (json_response.dig("details", "errors") || []).join(" ") + " " +
               json_response["error"].to_s + " " + json_response["message"].to_s

        expect(body).to match(/remote instance url/i)
        expect(body).not_to include("Gate evaluation failed")
      end
    end
  end

  describe "a valid payload still routes through the gate" do
    it "parks the proposal on the account with no policy rows" do
      post_create(parked_user, valid_attrs)

      expect(response).to have_http_status(:accepted)
      expect(json_response_data["pending"]).to eq(true)
      expect(::System::FederationPeer.where(account_id: parked_account.id).count).to eq(0),
                                                                                     "a federation peer was proposed without an approval gate"

      deferred = ::Ai::DeferredOperation.order(created_at: :desc).first
      expect(deferred).to be_present, "POST did not route through the autonomy gate"
      expect(deferred.action_category).to eq("sdwan.federation_peer_propose")
      expect(deferred.executor_class).to eq("Sdwan::Executors::ProposeFederationPeer")
      expect(deferred.params.dig("attributes", "remote_instance_url")).to eq("https://peer.example.test")
    end

    it "proposes the peer at 201 on the account whose policy proceeds" do
      post_create(proceeding_user, valid_attrs)

      expect(response).to have_http_status(:created)
      peer = json_response_data["federation_peer"]
      expect(peer["remote_instance_url"]).to eq("https://peer.example.test")
      expect(peer["status"]).to eq("proposed")
      expect(::System::FederationPeer.find_by(account_id: proceeding_account.id,
                                              remote_instance_url: "https://peer.example.test")).to be_present
    end

    it "proposes the peer when the parked operation is approved" do
      post_create(parked_user, valid_attrs)
      approve_latest_deferred!

      expect(::System::FederationPeer.find_by(account_id: parked_account.id,
                                              remote_instance_url: "https://peer.example.test")).to be_present
    end
  end
end
