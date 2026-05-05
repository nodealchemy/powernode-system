# frozen_string_literal: true

# Companion seed for docs/examples/05-cve-response-walkthrough.md.
#
# Drill-mode CVE response demonstration. Inserts a synthetic CVE-2026-DRILL-001
# directly via ActiveRecord (since system_create_cve is in the MCP gap backlog),
# computes exposure, runs cve_response skill, generates runbook.
#
# Idempotent: if the drill CVE exists, updates rather than duplicates.
#
# Run via:
#   cd server && bundle exec rails runner \
#     "load Rails.root.join('../extensions/system/server/db/seeds/example_cve_response.rb')"

puts "\n  Seeding example_cve_response (Example 05)..."

account = ::Account.first
return puts("  ⚠️  No account — skipping") unless account
user = account.users.find_by(email: "admin@powernode.org") || account.users.first
return puts("  ⚠️  No admin user — skipping") unless user

# ── Insert synthetic CVE (drill) ──────────────────────────────────────────

drill_cve_id = "CVE-2026-DRILL-001"

cve = ::System::Cve.find_or_initialize_by(cve_id: drill_cve_id)
cve.assign_attributes(
  severity: "critical",
  cvss_score: 9.8,
  affected_packages: [{ "name" => "openssl", "version" => "<3.1.4" }],
  summary: "DRILL: Synthetic OpenSSL TLS handshake RCE — for example 05 walkthrough only",
  published_at: Time.current,
  source: "DRILL"
)
cve.save!
puts "  ✅ Drill CVE: #{drill_cve_id} (#{cve.previously_new_record? ? 'created' : 'updated'})"

# ── Run cve_response skill ────────────────────────────────────────────────

executor = ::System::Ai::Skills::CveResponseExecutor.new(
  account: account, agent: nil, user: user
)

result = executor.execute(
  cve_id: drill_cve_id,
  severity: "critical",
  affected_packages: [{ name: "openssl", version: "<3.1.4" }],
  summary: cve.summary
)

if result[:success]
  data = result[:data]
  puts "  ✅ cve_response triage:"
  puts "       risk_score:             #{data[:risk_score]}"
  puts "       exposed_modules:        #{data[:exposed_modules]&.map { |m| m[:name] }&.join(', ')}"
  puts "       exposed_instance_count: #{data[:exposed_instance_count]}"
  puts "       requires_approval:      #{data[:requires_approval]}"
else
  puts "  ⚠️  cve_response failed: #{result[:error]}"
end

# ── Generate operator runbook ─────────────────────────────────────────────

runbook_executor = ::System::Ai::Skills::CveRunbookGenerateExecutor.new(
  account: account, agent: nil, user: user
)

runbook_result = runbook_executor.execute(
  cve_id: drill_cve_id,
  persist_as_page: false   # keep ephemeral for drill
)

if runbook_result[:success]
  rb = runbook_result[:data]
  puts "  ✅ cve_runbook_generate:"
  puts "       runbook_markdown:       #{rb[:runbook_markdown]&.length || 0} chars"
  puts "       exposed_module_count:   #{rb[:exposed_module_count]}"
  puts "       exposed_instance_count: #{rb[:exposed_instance_count]}"
  puts "       risk_score:             #{rb[:risk_score]}"
else
  puts "  ⚠️  cve_runbook_generate failed: #{runbook_result[:error]}"
end

puts "  ℹ️  Drill complete. Real CVE response would proceed to:"
puts "       - operator approval (require_approval policy)"
puts "       - rolling_module_upgrade execution"
puts "       - exposure verification (zero remaining)"
puts "       - learning extraction"

# ── Cleanup: remove the drill CVE ────────────────────────────────────────

puts "  ℹ️  Drill CVE retained for inspection. To clean up:"
puts "       System::Cve.where(cve_id: '#{drill_cve_id}').destroy_all"

puts "  Done. See docs/examples/05-cve-response-walkthrough.md."
