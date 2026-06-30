# frozen_string_literal: true

require "rails_helper"

# Coverage for the anonymous SDWAN bootstrap endpoint
# (GET /api/v1/system/sdwan/bootstrap/:token). Security-critical and previously
# untested: the token IS the auth (the controller skips authenticate_request),
# the 200 response embeds the device's WireGuard private key, and the link is
# single-use. This spec pins every HTTP status branch plus the single-use
# guarantee, so a regression cannot silently re-enable replay of a one-time link
# or serve config for a revoked device.
#
# WgConfigRenderer is stubbed on the happy path to keep the request spec
# hermetic (no Vault dependency) — this spec targets the controller's HTTP
# enforcement, not config rendering (which is exercised elsewhere).
RSpec.describe "Api::V1::System::Sdwan::Bootstrap", type: :request do
  let(:account) { create(:account) }
  let(:network) { create(:sdwan_network, account: account) }
  let(:grant)   { create(:sdwan_access_grant, account: account, network: network) }

  # A real, signed bootstrap token + persisted device, minted exactly as the
  # issuer does in production (grant must be active at issue time).
  let(:issued) { Sdwan::UserDeviceIssuer.issue!(grant: grant, label: "laptop") }
  let(:device) { issued[:device] }
  let(:token)  { issued[:bootstrap_token] }

  def get_bootstrap(tok)
    get "/api/v1/system/sdwan/bootstrap/#{tok}"
  end

  describe "GET /api/v1/system/sdwan/bootstrap/:token" do
    context "with a valid, unused token" do
      before do
        allow(Sdwan::WgConfigRenderer).to receive(:render)
          .and_return("# wg config\n[Interface]\nPrivateKey = secret\n")
      end

      it "returns 200 text/plain with the WireGuard config" do
        get_bootstrap(token)

        expect(response).to have_http_status(:ok)
        expect(response.media_type).to eq("text/plain")
        expect(response.body).to include("[Interface]")
      end

      it "consumes the one-time link (marks the device downloaded)" do
        get_bootstrap(token)

        expect(response).to have_http_status(:ok)
        expect(device.reload.last_downloaded_at).to be_present
      end

      it "rejects a second fetch of the same token with 410 Gone (single-use)" do
        get_bootstrap(token)
        expect(response).to have_http_status(:ok)

        get_bootstrap(token)
        expect(response).to have_http_status(:gone)
        expect(response.body).to include("already been used")
      end
    end

    context "with a blank token" do
      it "returns 400 without consulting the verifier" do
        get_bootstrap("%20") # a single space → params[:token].blank?

        expect(response).to have_http_status(:bad_request)
        expect(response.body).to include("missing token")
      end
    end

    context "with an invalid / unsigned token" do
      it "returns 401" do
        get_bootstrap("not-a-real-token")

        expect(response).to have_http_status(:unauthorized)
        expect(response.body).to include("invalid or expired")
      end
    end

    context "when the device referenced by the token no longer exists" do
      it "returns 404" do
        tok = token
        device.destroy!

        get_bootstrap(tok)

        expect(response).to have_http_status(:not_found)
        expect(response.body).to include("device not found")
      end
    end

    context "when the device has been revoked" do
      it "returns 410 Gone and does not serve config" do
        device.update!(revoked_at: Time.current)

        get_bootstrap(token)

        expect(response).to have_http_status(:gone)
        expect(response.body).to include("revoked")
      end
    end

    context "when the underlying access grant is not active" do
      it "returns 410 Gone" do
        device # mint while the grant is still active
        grant.update!(status: "suspended")

        get_bootstrap(token)

        expect(response).to have_http_status(:gone)
        expect(response.body).to include("access grant is not active")
      end
    end
  end
end
