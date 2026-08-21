# frozen_string_literal: true

require "rails_helper"

# IMP-32978416b9d3 — explicit `port_range: null` on PATCH silently no-ops.
#
# Rails 8.1.3 strong params (ActionController::Parameters#hash_filter,
# actionpack/lib/action_controller/metal/strong_parameters.rb:1354,
# `next unless value`) drops a nil-valued permitted key entirely at permit
# time. FirewallRulesController#rule_params therefore never sees an
# explicit `port_range: null` — it looks identical to the key being absent
# by the time it reaches the controller. `{}` survives permit (a Hash is
# truthy) and already clears today via Sdwan::FirewallRule#port_range_hash=.
#
# The fix reads params[:firewall_rule] — the RAW, unpermitted request
# params — to detect the nil-valued key BEFORE strong-params filtering can
# drop it, then routes the clear through #port_range_hash= (whose nil
# contract IS "clear"), never through #port_range= (whose nil contract is
# "not provided — leave untouched", by design, per IMP-0e44cf2fc80b).
RSpec.describe "Api::V1::System::Sdwan::FirewallRules port_range explicit-null clear", type: :request do
  let(:user)    { user_with_permissions("system.sdwan.firewall.manage", "system.sdwan.firewall.read") }
  let(:account) { user.account }

  let!(:network) { create(:sdwan_network, account: account) }
  let!(:rule) do
    create(:sdwan_firewall_rule, account: account, network: network, protocol: "tcp",
                                  dst_port_range: (8000..8080))
  end

  def member_path = "/api/v1/system/sdwan/networks/#{network.id}/firewall_rules/#{rule.id}"

  def patch_update(body)
    patch member_path, params: body.to_json,
          headers: auth_headers_for(user).merge("Content-Type" => "application/json")
  end

  # Shape 1: explicit null must CLEAR.
  it "clears port_range when the payload sends port_range: null explicitly" do
    patch_update(firewall_rule: { port_range: nil })

    expect(response).to have_http_status(:accepted)
    approve_latest_deferred!

    expect(rule.reload.port_range_hash).to be_nil,
                                            "explicit port_range: null did not clear the range"
  end

  # Shape 2: {} already clears today (empty hash survives strong-params
  # permit since it's truthy) — the fix must not break this path.
  it "clears port_range when the payload sends port_range: {}" do
    patch_update(firewall_rule: { port_range: {} })

    expect(response).to have_http_status(:accepted)
    approve_latest_deferred!

    expect(rule.reload.port_range_hash).to be_nil,
                                            "port_range: {} stopped clearing the range"
  end

  # Shape 3: the catch for an over-broad fix. If clearing fired whenever the
  # key is merely absent, every unrelated PATCH would silently wipe
  # port_range. Assert status too, so "nothing changed because it 500'd"
  # cannot masquerade as "nothing changed because it was preserved".
  it "preserves the existing port_range when the key is absent from the payload" do
    patch_update(firewall_rule: { name: "renamed-rule" })

    expect(response).to have_http_status(:accepted)
    approve_latest_deferred!

    rule.reload
    expect(rule.name).to eq("renamed-rule")
    expect(rule.port_range_hash).to eq({ from: 8000, to: 8080 }),
                                     "an unrelated field update silently cleared port_range"
  end
end
