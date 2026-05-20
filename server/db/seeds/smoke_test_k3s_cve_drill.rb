# frozen_string_literal: true

# K3s full-lifecycle smoke — Phase 7: CVE response drill.
#
# Synthetic CVE → CveResponseExecutor → triage + risk scoring +
# CveRunbookGenerateExecutor. Mirrors example_cve_response.rb's pattern
# (find_or_initialize_by + executor invocation). Validates that the full
# response chain wires through without erroring + produces a runbook.
#
# At db tier: synthetic CVE-2026-99099, triage executor returns success,
# runbook generator produces markdown. No actual module upgrade fires
# (that would require fleet_autonomy reconciler tick + ApprovalRequest
# chain). Drill validates the upstream half of the response pipeline.
#
# Asserts:
#   - System::Cve row created with drill metadata
#   - CveResponseExecutor returns success with triage data
#   - data has :risk_score, :exposed_modules, :exposed_instance_count
#   - CveRunbookGenerateExecutor returns success with markdown
#
# Cleanup: drill CVE is destroyed at end (matches drill convention; the
# example_cve_response.rb pattern retains it for inspection, but smoke
# wants a clean slate).
#
# Invoke:
#   cd server && SMOKE_K3S_LEVEL=db bundle exec rails runner \
#     "load Rails.root.join('../extensions/system/server/db/seeds/smoke_test_k3s_cve_drill.rb')"

require_relative "_smoke_k3s_helpers"

h = ::System::Seeds::SmokeK3sHelpers

puts "\n  K3s lifecycle smoke — Phase 7: CVE response drill"
puts "  ============================================================"
puts "  Tier:           #{h.current_tier}"

begin
  h.tier_gate(required: "db")
rescue ::System::Seeds::SmokeK3sHelpers::TierInsufficient => e
  h.skipped(e.message)
  exit 0
end

h.preflight!(level: h.current_tier)
account = h.discover_or_create_account!
user = account.users.find_by(email: "admin@powernode.org") || account.users.first
h.fail_with("no admin user on account") unless user

# ── Insert synthetic drill CVE ──────────────────────────────────────
drill_cve_id = "CVE-2026-99099"
h.step("Insert synthetic drill CVE #{drill_cve_id}")

cve = ::System::Cve.find_or_initialize_by(cve_id: drill_cve_id)
cve.assign_attributes(
  severity: "critical",
  affected_packages: [ { "name" => "openssl", "version" => "<3.1.4" } ],
  summary: "SMOKE DRILL: synthetic CVE for k3s lifecycle smoke test",
  published_at: Time.current,
  feed_source: "DRILL",
  metadata: { "cvss_score" => 9.5, "drill" => true, "smoke" => "k3s_lifecycle" }
)
cve.save!
h.ok("drill CVE #{cve.previously_new_record? ? 'created' : 'updated'}")

begin
  # ── Run CveResponseExecutor ───────────────────────────────────────
  h.step("Invoke CveResponseExecutor (triage + risk scoring + exposure scan)")

  triage = ::System::Ai::Skills::CveResponseExecutor.new(
    account: account, agent: nil, user: user
  ).execute(
    cve_id: drill_cve_id,
    severity: "critical",
    affected_packages: [ { name: "openssl", version: "<3.1.4" } ],
    summary: cve.summary
  )

  h.assert(triage[:success], "triage executor returned success (got #{triage.inspect[0, 200]})")
  data = triage[:data] || {}
  h.assert(data.key?(:risk_score), "triage.data has :risk_score (got #{data[:risk_score]})")
  h.assert(data.key?(:exposed_modules), "triage.data has :exposed_modules")
  h.assert(data.key?(:exposed_instance_count), "triage.data has :exposed_instance_count")
  h.ok("risk_score=#{data[:risk_score]} exposed_modules=#{Array(data[:exposed_modules]).size} " \
       "exposed_instances=#{data[:exposed_instance_count]}")

  # ── Run CveRunbookGenerateExecutor ────────────────────────────────
  h.step("Invoke CveRunbookGenerateExecutor")

  runbook = ::System::Ai::Skills::CveRunbookGenerateExecutor.new(
    account: account, agent: nil, user: user
  ).execute(
    cve_id: drill_cve_id,
    persist_as_page: false
  )

  h.assert(runbook[:success], "runbook executor returned success (got #{runbook.inspect[0, 200]})")
  rb_data = runbook[:data] || {}
  h.assert(rb_data.key?(:runbook_markdown), "runbook.data has :runbook_markdown")
  markdown = rb_data[:runbook_markdown].to_s
  h.assert(markdown.length > 0, "runbook markdown is non-empty (got #{markdown.length} chars)")
  h.assert(markdown.include?(drill_cve_id), "runbook markdown mentions #{drill_cve_id}")
  h.ok("runbook generated (#{markdown.length} chars)")
ensure
  # ── Cleanup ───────────────────────────────────────────────────────
  h.step("Cleanup drill CVE")
  destroyed = ::System::Cve.where(cve_id: drill_cve_id).destroy_all
  h.ok("destroyed #{destroyed.size} drill CVE row(s)")
end

puts "\n  ✅ Phase 7 (CVE drill) complete"
puts "  Synthetic CVE response chain validated"
puts "  Next: smoke_test_k3s_drain_reprovision.rb"
