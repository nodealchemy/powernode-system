# frozen_string_literal: true

require "rails_helper"

# IMP-01a05ae8 — the operator read surface for System::Fleet::RemediationOutcome.
#
# An outcome is the fleet's ground truth for "did the autonomous fix actually
# clear the signal": pending while it settles, then effective / ineffective by
# re-sensing, or inconclusive. Until this endpoint it was read only by the
# autonomy internals (DecisionEngine's stuck-streak and deferral brakes, two
# sensors), so an operator could not see which remediations work, and could
# not see which fingerprints the engine had given up on.
#
# The stuck list is asserted against RemediationOutcome.ineffective_streak and
# DecisionEngine::STUCK_STREAK_THRESHOLD directly — the exact rule the engine
# escalates on — so the dashboard cannot drift into a second, rival definition.
RSpec.describe "GET /api/v1/system/fleet/remediation_outcomes", type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, :admin, account: account) }
  let(:threshold) { ::System::Fleet::DecisionEngine::STUCK_STREAK_THRESHOLD }

  def outcome!(status:, signal_kind: "system.module_drift", fingerprint: "fp-#{SecureRandom.hex(4)}",
               acted_at: 1.day.ago, validated_at: nil, owner: account)
    ::System::Fleet::RemediationOutcome.create!(
      account: owner, signal_kind: signal_kind, fingerprint: fingerprint, status: status,
      acted_at: acted_at, settle_until: acted_at + 10.minutes,
      validated_at: validated_at || (status == "pending" ? nil : acted_at + 15.minutes)
    )
  end

  # `threshold` ineffective settles in a row for one fingerprint, oldest first.
  def streak!(fingerprint, count:, signal_kind: "system.module_drift", starting: 6.hours.ago, owner: account)
    count.times do |i|
      outcome!(status: "ineffective", fingerprint: fingerprint, signal_kind: signal_kind,
               acted_at: starting + i.hours, owner: owner)
    end
  end

  def fetch(user = admin, **query)
    get "/api/v1/system/fleet/remediation_outcomes", params: query, headers: auth_headers_for(user)
    json_response["data"]
  end

  def kind_row(data, kind)
    data["kinds"].find { |k| k["signal_kind"] == kind }
  end

  it "summarises each signal kind by status and scores effectiveness over settled rows only" do
    3.times { outcome!(status: "effective") }
    outcome!(status: "ineffective")
    2.times { outcome!(status: "pending") }
    outcome!(status: "inconclusive")
    2.times { outcome!(status: "pending", signal_kind: "system.cert_expiring") }

    data = fetch
    expect(response).to have_http_status(:ok)

    drift = kind_row(data, "system.module_drift")
    expect(drift).to include("effective" => 3, "ineffective" => 1, "pending" => 2, "inconclusive" => 1, "settled" => 4)
    # 3 effective of 4 scored — pending and inconclusive carry no score.
    expect(drift["effectiveness_rate"]).to eq(0.75)

    # Nothing settled yet: no rate, rather than a misleading 0%.
    expect(kind_row(data, "system.cert_expiring")).to include("pending" => 2, "settled" => 0, "effectiveness_rate" => nil)

    expect(data["totals"]).to include("effective" => 3, "ineffective" => 1, "pending" => 4, "inconclusive" => 1,
                                      "effectiveness_rate" => 0.75)
  end

  it "counts only outcomes acted within the window, and the window is adjustable" do
    outcome!(status: "effective", acted_at: 1.day.ago)
    outcome!(status: "ineffective", acted_at: 10.days.ago)

    expect(fetch["totals"]).to include("effective" => 1, "ineffective" => 0)
    expect(fetch(window_days: 30)["totals"]).to include("effective" => 1, "ineffective" => 1)
  end

  describe "the stuck list" do
    it "lists a fingerprint exactly when the engine's own streak reaches the threshold" do
      streak!("fp-stuck", count: threshold)

      # Same number of failures, but the newest settle was effective: the
      # engine's take_while resets, so this one is NOT stuck.
      streak!("fp-recovered", count: threshold, starting: 9.hours.ago)
      outcome!(status: "effective", fingerprint: "fp-recovered", acted_at: 1.hour.ago)

      streak!("fp-short", count: threshold - 1)

      stuck = fetch["stuck"]
      expect(stuck["threshold"]).to eq(threshold)
      expect(stuck["fingerprints"].map { |f| f["fingerprint"] }).to eq([ "fp-stuck" ])
      expect(stuck["fingerprints"].first).to include("signal_kind" => "system.module_drift", "streak" => threshold)

      # Parity with the rule the engine escalates on, for listed AND unlisted.
      %w[fp-stuck fp-recovered fp-short].each do |fp|
        engine_streak = ::System::Fleet::RemediationOutcome.ineffective_streak(account: account, fingerprint: fp)
        listed = stuck["fingerprints"].any? { |f| f["fingerprint"] == fp }
        expect(listed).to eq(engine_streak >= threshold), "#{fp}: engine streak #{engine_streak}, listed=#{listed}"
      end
    end

    # The list is the engine's current view: bounded by the engine's own
    # RemediationOutcome::STUCK_STREAK_WINDOW (a streak older than that is one the
    # engine retries, IMP-a294e9db40ea), and NOT by the summary's `window_days`.
    it "is bounded by the engine's streak window, not by the summary window" do
      streak!("fp-aged-out", count: threshold, starting: 20.days.ago, signal_kind: "system.config_drift")
      streak!("fp-current", count: threshold, starting: 6.hours.ago, signal_kind: "system.config_drift")

      narrow = fetch(window_days: 1)
      wide = fetch(window_days: 90)

      expect(narrow["stuck"]["fingerprints"].map { |f| f["fingerprint"] }).to eq([ "fp-current" ])
      expect(wide["stuck"]["fingerprints"].map { |f| f["fingerprint"] }).to eq([ "fp-current" ])
    end

    # Only the kinds the engine retries age out (RemediationOutcome::STUCK_STREAK_RETRY_KINDS).
    it "keeps listing an old streak of a kind the engine does not retry" do
      streak!("fp-old-module-drift", count: threshold, starting: 20.days.ago)

      expect(fetch["stuck"]["fingerprints"].map { |f| f["fingerprint"] }).to eq([ "fp-old-module-drift" ])
    end
  end

  it "never counts or lists another account's outcomes" do
    other = create(:account)
    3.times { outcome!(status: "effective", owner: other) }
    streak!("fp-foreign", count: threshold, owner: other)
    outcome!(status: "effective")

    data = fetch
    expect(data["totals"]).to include("effective" => 1, "ineffective" => 0)
    expect(data["stuck"]["fingerprints"]).to be_empty
  end

  it "refuses a user without system.fleet.read" do
    outcome!(status: "effective")
    nobody = create(:user, account: account, permissions: [])

    get "/api/v1/system/fleet/remediation_outcomes", headers: auth_headers_for(nobody)
    expect(response).to have_http_status(:forbidden)
  end
end
