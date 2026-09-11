# frozen_string_literal: true

require "rails_helper"

# POST /api/v1/system/fleet/signals — the typed entity filters the component
# drawer's per-component signals view reads (design §6, signals ruling).
#
# The view filters by the fleet event's TYPED column — node_instance_id,
# node_module_id, certificate_id — never by payload keys. Four properties,
# each asserted on both arms:
#
#   narrow, never widen   every filter is applied ON TOP of the caller's
#                         account scope; another account's row with the same
#                         id is never returned.
#   NULL is not a value   a row whose column is NULL recorded no entity, and no
#                         filter value ever matches it. This is load-bearing:
#                         Rails casts a malformed uuid to nil, so a naive
#                         where(column => params[...]) would turn "garbage" into
#                         WHERE column IS NULL and return exactly the rows that
#                         recorded nothing. A malformed value is refused (422).
#   blank is absent       an empty value is no filter, as the kind and
#                         correlation filters already behave.
#   AND                   several filters combine by intersection.
RSpec.describe "POST /api/v1/system/fleet/signals typed entity filters", type: :request do
  let(:account)       { create(:account) }
  let(:other_account) { create(:account) }
  let(:user)    { user_with_permissions("system.fleet.read", account: account) }
  let(:headers) { auth_headers_for(user).merge("Content-Type" => "application/json") }

  COLUMNS = %w[node_instance_id node_module_id certificate_id].freeze

  def event(owner: account, **attrs)
    System::FleetEvent.create!(
      account: owner, kind: "system.filter_probe", severity: "low", emitted_at: Time.current, **attrs
    )
  end

  def signals(params = {})
    post "/api/v1/system/fleet/signals", params: params.to_json, headers: headers
    response
  end

  def returned_ids
    JSON.parse(response.body).dig("data", "events").map { |e| e["id"] }
  end

  COLUMNS.each do |column|
    describe "the #{column} filter" do
      let(:value) { SecureRandom.uuid }
      let!(:match)         { event(column.to_sym => value) }
      let!(:other_value)   { event(column.to_sym => SecureRandom.uuid) }
      let!(:not_recorded)  { event(column.to_sym => nil) }
      let!(:other_account_same_value) { event(owner: other_account, column.to_sym => value) }

      it "returns only this account's events whose #{column} is the value" do
        expect(signals(column => value)).to have_http_status(:ok)
        expect(returned_ids).to eq([ match.id ])
      end

      # The other arm: without the filter the same request returns every one
      # of this account's rows, so the exclusions above are the filter's doing.
      it "returns all of this account's events, and none of another's, without it" do
        signals
        expect(returned_ids).to contain_exactly(match.id, other_value.id, not_recorded.id)
      end

      it "never matches a row whose #{column} was not recorded" do
        signals(column => value)
        expect(returned_ids).not_to include(not_recorded.id)
      end

      it "refuses a malformed value with 422 naming #{column}, rather than matching NULL rows" do
        %w[not-a-uuid 123].each do |bad|
          expect(signals(column => bad)).to have_http_status(:unprocessable_content)
          expect(response.body).to include(column)
        end
      end

      it "treats a blank value as no filter" do
        signals(column => "")
        expect(response).to have_http_status(:ok)
        expect(returned_ids).to contain_exactly(match.id, other_value.id, not_recorded.id)
      end

      it "returns nothing, not a wider scope, when only another account's row matches" do
        foreign_only = SecureRandom.uuid
        event(owner: other_account, column.to_sym => foreign_only)

        expect(signals(column => foreign_only)).to have_http_status(:ok)
        expect(returned_ids).to eq([])
      end
    end
  end

  describe "several filters" do
    let(:instance_id) { SecureRandom.uuid }
    let(:module_id)   { SecureRandom.uuid }
    let!(:both)          { event(node_instance_id: instance_id, node_module_id: module_id) }
    let!(:instance_only) { event(node_instance_id: instance_id, node_module_id: SecureRandom.uuid) }
    let!(:module_only)   { event(node_instance_id: SecureRandom.uuid, node_module_id: module_id) }
    let!(:foreign_both)  { event(owner: other_account, node_instance_id: instance_id, node_module_id: module_id) }

    it "combine with AND" do
      signals(node_instance_id: instance_id, node_module_id: module_id)
      expect(returned_ids).to eq([ both.id ])
    end

    it "each still narrows on its own (the other arm of AND)" do
      signals(node_instance_id: instance_id)
      expect(returned_ids).to contain_exactly(both.id, instance_only.id)
    end

    it "combine with the existing kind filter" do
      kinded = event(kind: "system.other_kind", node_instance_id: instance_id)
      signals(node_instance_id: instance_id, kind: "system.other_kind")
      expect(returned_ids).to eq([ kinded.id ])
    end
  end

  # The account scope the filters narrow is where(account: current account).
  # A NULL-account fleet event cannot exist — the column is NOT NULL — so there
  # is no NULL-account row for a filter to keep or drop; this pins the
  # constraint that makes that true, so relaxing it forces this question to be
  # asked again.
  it "sits on an account_id column that cannot be NULL" do
    expect(System::FleetEvent.columns_hash.fetch("account_id").null).to be(false)
  end
end
