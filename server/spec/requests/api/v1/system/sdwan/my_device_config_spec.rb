# frozen_string_literal: true

require "rails_helper"

# Coverage for the AUTHENTICATED self-service config endpoint
# (GET /api/v1/system/sdwan/my_devices/:id/config) — the delivery path for a
# device issued WITHOUT a bootstrap token, which has no other route to its
# config.
#
# ============================================================================
# NO-KEY-OUTPUT RULE — WHY EVERY KEY ASSERTION IS A BARE BOOLEAN
# ============================================================================
# This endpoint's 200 body contains a real X25519 private key (synthetic, minted
# by KeyDistributor inside this process — but treated as key material
# regardless). `expect(body).to include(key)` would print BOTH operands on red,
# and ActiveRecord's attributes_for_inspect narrows to [:id] only in production,
# so rendering a device in a failure message would dump encrypted_credentials —
# the Base64-JSON of that private key — into dev and CI logs.
#
# So: every key-related expectation reduces to `be(true)` / `be(false)` with a
# hand-written message that names no value, and no example ever passes a
# UserDevice to a matcher.
#
# The renderer is NOT stubbed here (unlike bootstrap_spec, which stubs it to stay
# hermetic). Serving a REAL key is the property under test: a status-only
# assertion passes just as happily while the endpoint serves the
# "<vault-unavailable>" placeholder config, which is exactly how a Vault outage
# would ship green.
RSpec.describe "Api::V1::System::Sdwan::MyDevices", type: :request do
  let(:account)  { create(:account) }
  let(:owner)    { create(:user, account: account) }
  # Same account, no grant of their own. The interesting refusal: an account
  # boundary would not catch them, only the ownership binding does.
  let(:intruder) { create(:user, account: account) }

  let(:network) { create(:sdwan_network, account: account) }
  let(:grant)   { create(:sdwan_access_grant, account: account, network: network, user: owner) }

  # Issued the way the agent arm will issue (increment 4): a complete, usable
  # device with NO bootstrap token. This endpoint is its only delivery path.
  let(:issued) do
    ::Sdwan::UserDeviceIssuer.issue!(grant: grant, label: "laptop", mint_bootstrap_token: false)
  end
  let(:device) { issued[:device] }

  # RE-FETCH BY ID — do not read the key off `issued[:device]`.
  #
  # VaultCredential#store_in_vault assigns `@vault_credentials = nil` into a
  # `defined?`-guarded memo, and `reload` does not clear an ivar. The instance
  # the issuer hands back therefore answers nil from private_key_b64 forever, in
  # every environment. Reading the expected key off that instance would make
  # every assertion below compare against nil and pass vacuously.
  let(:expected_private_key) { ::Sdwan::UserDevice.find(device.id).private_key_b64 }

  def config_path(dev)
    "/api/v1/system/sdwan/my_devices/#{dev.id}/config"
  end

  def stored_device
    ::Sdwan::UserDevice.find(device.id)
  end

  # Guards the guard: if the test environment ever stopped round-tripping the
  # key through the DB fallback, `expected_private_key` would be nil and every
  # "carries the key" assertion below would degrade to "body contains nil",
  # which is trivially true-ish. Fail loudly on that instead.
  before do
    expect(expected_private_key.to_s.empty?).to be(false),
                                                "setup produced no private key to assert on — " \
                                                "the vault/DB credential round-trip is broken, " \
                                                "so no key assertion in this file means anything"
  end

  describe "the owner" do
    it "receives a 200 text/plain config that carries a REAL private key" do
      get config_path(device), headers: auth_headers_for(owner)

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("text/plain")
      expect(response.body.include?(expected_private_key)).to be(true),
                                                              "200 body did not carry the device's private key"
      expect(response.body.include?("vault-unavailable")).to be(false),
                                                             "served the placeholder config as a success"
    end

    it "gets a config for a device that never had a bootstrap token" do
      expect(issued[:bootstrap_token].nil?).to be(true), "fixture minted a token; wrong shape under test"

      get config_path(device), headers: auth_headers_for(owner)

      expect(response).to have_http_status(:ok)
      expect(response.body.include?("[Interface]")).to be(true)
    end

    # POSITIVE CONTROL. Every other ownership example asserts a refusal, and a
    # scope that refused EVERYTHING would satisfy all of them. This one proves
    # the scope still SELECTS, and selects the right row when the owner holds
    # more than one device.
    it "gets the requested device, not merely 'a' device they own" do
      other_device = ::Sdwan::UserDeviceIssuer.issue!(
        grant: grant, label: "desktop", mint_bootstrap_token: false
      )[:device]
      other_key = ::Sdwan::UserDevice.find(other_device.id).private_key_b64

      get config_path(other_device), headers: auth_headers_for(owner)

      expect(response).to have_http_status(:ok)
      expect(response.body.include?(other_key)).to be(true),
                                                   "served the wrong device's config"
      expect(response.body.include?(expected_private_key)).to be(false),
                                                              "served the OTHER device's private key"
    end

    # Every other 200 example runs against the bare `sdwan_network` factory,
    # which creates NO peers — so the renderer emits a hub warning and zero
    # [Peer] sections. Those examples prove a real KEY is served; this one
    # proves a CONNECTABLE config is, which is the property a user actually
    # needs. (A peerless 200 is deliberate, not a bug — see the controller's
    # "SCOPE OF THIS GUARD" note.)
    it "serves a connectable config when the network has a reachable, keyed hub" do
      hub = create(:sdwan_peer, :hub, account: account, network: network)
      ::Sdwan::PeerKey.create!(peer: hub, public_key: Base64.strict_encode64(SecureRandom.bytes(32)))

      get config_path(device), headers: auth_headers_for(owner)

      expect(response).to have_http_status(:ok)
      expect(response.body.include?("[Peer]")).to be(true),
                                                  "config carried no [Peer] section, so it cannot connect"
      expect(response.body.include?(expected_private_key)).to be(true)
    end

    it "stamps last_downloaded_at so the staleness sensor sees the render clock" do
      expect(stored_device.last_downloaded_at.nil?).to be(true)

      get config_path(device), headers: auth_headers_for(owner)

      expect(response).to have_http_status(:ok)
      expect(stored_device.last_downloaded_at.nil?).to be(false)
    end

    # JUDGEMENT CALL (a): single-use is the anonymous TOKEN's property, not the
    # owner's. See Sdwan::UserDevice#owner_retrievable? for the full reasoning.
    # A second fetch discloses nothing the first did not, and refusing it would
    # strand a token-less device on one fumbled copy/paste.
    it "may re-fetch — single-use does NOT carry over to the authenticated path" do
      get config_path(device), headers: auth_headers_for(owner)
      expect(response).to have_http_status(:ok)

      get config_path(device), headers: auth_headers_for(owner)

      expect(response).to have_http_status(:ok)
      expect(response.body.include?(expected_private_key)).to be(true),
                                                              "second owner fetch did not carry the private key"
    end
  end

  # "No in-flight bootstrap link may break" is a requirement of this increment,
  # so the interaction between the two delivery paths is pinned rather than
  # assumed. It is deliberately one-way — see UserDevice#owner_retrievable?.
  describe "interaction with the anonymous bootstrap link" do
    let(:tokened) do
      ::Sdwan::UserDeviceIssuer.issue!(grant: grant, label: "phone", mint_bootstrap_token: true)
    end

    it "leaves owner retrieval intact after the bootstrap link is consumed" do
      get "/api/v1/system/sdwan/bootstrap/#{tokened[:bootstrap_token]}"
      expect(response).to have_http_status(:ok)

      key = ::Sdwan::UserDevice.find(tokened[:device].id).private_key_b64
      get config_path(tokened[:device]), headers: auth_headers_for(owner)

      expect(response).to have_http_status(:ok)
      expect(response.body.include?(key)).to be(true),
                                             "owner could not retrieve after the one-shot link was consumed"
    end

    # The other direction: delivery HAPPENED, so the bearer URL is spent. That
    # is single-use working, not a regression — a bootstrap URL outliving its
    # own delivery is exactly what it exists to prevent.
    it "spends the one-shot link once the owner has self-served" do
      tokened
      get config_path(tokened[:device]), headers: auth_headers_for(owner)
      expect(response).to have_http_status(:ok)

      get "/api/v1/system/sdwan/bootstrap/#{tokened[:bootstrap_token]}"

      expect(response).to have_http_status(:gone)
      expect(response.body.include?("already been used")).to be(true)
    end
  end

  describe "a different user in the same account" do
    it "is refused AND receives no key material in the body" do
      get config_path(device), headers: auth_headers_for(intruder)

      expect(response).to have_http_status(:not_found)
      expect(response.body.include?(expected_private_key)).to be(false),
                                                              "refused response disclosed the private key"
      expect(response.body.include?("[Interface]")).to be(false),
                                                       "refused response carried a WireGuard config section"
      expect(response.body.include?("PrivateKey")).to be(false),
                                                      "refused response carried a PrivateKey line"
    end

    it "cannot burn the owner's access with a failed probe" do
      get config_path(device), headers: auth_headers_for(intruder)
      expect(response).to have_http_status(:not_found)

      expect(stored_device.last_downloaded_at.nil?).to be(true),
                                                       "a refused probe stamped last_downloaded_at on the owner's device"
    end

    # The account boundary must not be what saves us: a user in ANOTHER account
    # is refused by the same one predicate, not by a separate code path.
    it "is refused when they belong to a different account entirely" do
      outsider = create(:user, account: create(:account))

      get config_path(device), headers: auth_headers_for(outsider)

      expect(response).to have_http_status(:not_found)
      expect(response.body.include?(expected_private_key)).to be(false),
                                                              "cross-account response disclosed the private key"
    end

    # THE VARIANT THAT CATCHES A LOST JOIN BINDING. Everywhere above, the
    # intruder holds NO grant at all, so a refusal could be produced by the
    # weaker property "this caller has zero grant rows" rather than by the one
    # that matters, "the grant joined to THIS device is not the caller's". Here
    # the intruder has their own active grant and their own device on the SAME
    # network — a scope that filtered on "caller has some grant" instead of on
    # the joined row would serve the owner's key straight to them.
    it "is refused even when they hold their own active grant on the same network" do
      intruder_grant = create(:sdwan_access_grant, account: account, network: network, user: intruder)
      create(:sdwan_user_device, access_grant: intruder_grant, label: "intruder-laptop")

      get config_path(device), headers: auth_headers_for(intruder)

      expect(response).to have_http_status(:not_found)
      expect(response.body.include?(expected_private_key)).to be(false),
                                                              "a grant-holding intruder received the OWNER's private key"
    end

    # ANTI-ENUMERATION, the endpoint's headline refusal property: "exists but
    # not yours" and "does not exist" must be one response, not two. Status-only
    # assertions would still pass if someone later "helpfully" 403'd the first
    # case, so compare the bodies byte for byte.
    it "returns a byte-identical body for 'not yours' and 'no such device'" do
      get config_path(device), headers: auth_headers_for(intruder)
      not_yours_status = response.status
      not_yours_body   = response.body

      get "/api/v1/system/sdwan/my_devices/#{UUID7.generate}/config", headers: auth_headers_for(intruder)

      expect(response.status).to eq(not_yours_status)
      expect(response.body).to eq(not_yours_body)
    end
  end

  describe "a malformed device id" do
    # The clean 404 rests on ActiveRecord's uuid cast returning nil for a
    # non-UUID string (so the predicate becomes `id IS NULL`). That is a gem
    # internal: if it ever changed to raise, this endpoint would 500 on garbage
    # input. Pin the behaviour we depend on rather than the gem.
    it "is a 404, not a 500" do
      get "/api/v1/system/sdwan/my_devices/not-a-uuid/config", headers: auth_headers_for(owner)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "an unauthenticated caller" do
    it "is refused with no key material" do
      get config_path(device)

      expect(response).to have_http_status(:unauthorized)
      expect(response.body.include?(expected_private_key)).to be(false),
                                                              "unauthenticated response disclosed the private key"
    end
  end

  # The ONE way to reach this action with current_user nil: core's
  # authenticate_request falls back to a forwarded mTLS client-cert identity and
  # sets current_worker instead. (worker_mtls_headers sends the Info header with
  # no PEM, i.e. the WEAKER :mtls_forwarded_cn posture — which is the right one
  # to test: it is the posture an ingress misconfiguration could hand an
  # attacker, and this endpoint must refuse it too.) An ownership predicate
  # written as `grant.user_id == current_user.id` would raise NoMethodError on
  # nil here — a 500, not a refusal. Verified by mutation: deleting the
  # current_user guard turns this example's 401 into a 500.
  describe "a WORKER principal (mTLS, no user)" do
    let(:worker) { create(:worker, account: account) }

    it "is refused with no key material" do
      get config_path(device), headers: worker_mtls_headers(worker)

      expect(response).to have_http_status(:unauthorized)
      # Pins that the request actually REACHED this controller. Core's
      # pre-action 401 renders JSON; only this action's refusal is text/plain.
      # Without it, a factory change that blanked node_instance_id would make
      # core reject the request first and leave this example green while the
      # guard it exists to pin never ran.
      expect(response.media_type).to eq("text/plain")
      expect(response.body.include?(expected_private_key)).to be(false),
                                                              "worker principal received the user's private key"
      expect(response.body.include?("[Interface]")).to be(false)
    end
  end

  describe "when access has been cut" do
    it "returns 410 and no key material for a revoked device" do
      device.update!(revoked_at: Time.current)

      get config_path(device), headers: auth_headers_for(owner)

      expect(response).to have_http_status(:gone)
      expect(response.body.include?("revoked")).to be(true)
      expect(response.body.include?(expected_private_key)).to be(false),
                                                              "revoked device still disclosed the private key"
    end

    it "returns 410 and no key material when the grant is suspended" do
      device # mint while active
      grant.update!(status: "suspended")

      get config_path(device), headers: auth_headers_for(owner)

      expect(response).to have_http_status(:gone)
      expect(response.body.include?("access grant is not active")).to be(true)
      expect(response.body.include?(expected_private_key)).to be(false),
                                                              "suspended grant still disclosed the private key"
    end

    # The other arm of AccessGrant#active?. Grant revocation cascades
    # revoked_at onto every device, so this lands on the "revoked" branch —
    # asserted so a future change that decoupled the cascade cannot leave a
    # revoked grant's device quietly retrievable.
    it "returns 410 and no key material when the grant is revoked" do
      device # mint while active
      grant.revoke!(reason: "offboarded")

      get config_path(device), headers: auth_headers_for(owner)

      expect(response).to have_http_status(:gone)
      expect(response.body.include?(expected_private_key)).to be(false),
                                                              "revoked grant still disclosed the private key"
    end
  end

  describe "when Vault cannot supply the private half" do
    # The renderer degrades to a placeholder instead of raising, so without the
    # controller's fail-closed guard this case would be a 200 carrying a config
    # that connects to nothing. Assert the refusal, not the wording.
    it "refuses rather than serving a placeholder config as a success" do
      allow_any_instance_of(::Sdwan::UserDevice).to receive(:private_key_b64).and_return(nil)

      get config_path(device), headers: auth_headers_for(owner)

      expect(response).to have_http_status(:service_unavailable)
      expect(response.body.include?("[Interface]")).to be(false),
                                                       "served a config body despite absent key material"
      # The key IS still retrievable here (the before hook memoized it before
      # the stub went in), so this is a real absence assertion, not a vacuous one.
      expect(response.body.include?(expected_private_key)).to be(false),
                                                              "503 body disclosed the private key"
      expect(stored_device.last_downloaded_at.nil?).to be(true),
                                                       "a failed retrieval stamped last_downloaded_at"
    end
  end
end
