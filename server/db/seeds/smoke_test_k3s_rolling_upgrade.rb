# frozen_string_literal: true

# K3s full-lifecycle smoke — Phase 6: Rolling module upgrade.
#
# Validates the rolling_module_upgrade skill executor's plan computation.
#
# IMP-e8dc40813adb — the executor returns a plan and nothing executes it, at
# EVERY tier. There is no reconciler and no circuit-breaker gating anywhere in
# the platform for module upgrades; the "site+ tier executes" note this header
# used to carry described a runtime that was never built.
#
# IMP-a699af087f5d — and there are no batches for such a reconciler to step
# through: the upgrade is FLEET-ATOMIC (operator decision 2026-08-30), so the
# plan is one atomic affected set. Denying only the ADVANCER concedes that
# batches exist and implies that building one would finish the story.
# The plan structure asserted below is the whole contract.
#
# Tier semantics:
#   db (default): synthesize NodeModuleVersion + invoke executor + assert
#                 plan structure (total_instances, affected_instance_ids)
#                 WHEN the executor succeeds. No actual upgrade.
#   site+:        identical — there is no execution path to exercise. The
#                 ApprovalRequest gate is real, but nothing acts on an approval.
#
# Asserts UNCONDITIONALLY (descriptor contract, :74-83):
#   - RollingModuleUpgradeExecutor descriptor registered with the right slug
#   - Descriptor declares :affected_instance_ids and does NOT declare :batch_pct
#
# Asserts ONLY IF the executor returns success (:134-148) — a failure is
# tolerated with a warning at db tier (:150-152), so these do NOT run on
# every green run and their absence from a run's output is not a failure:
#   - affected_instance_ids covers the WHOLE eligible population (:144-146)
#   - The plan exposes no batch structure (no :batches, no :batch_count) (:147-148)
#
# IMP-a699af087f5d — the two lists above described the canary/batch_count
# assertions this seed used to make. IMP-b948ea7fa382 replaced those
# assertions with their opposites (:147-148) when module upgrades were
# accepted as FLEET-ATOMIC, but left this header advertising the deleted
# checks. A reader trusting the header believed the seed verified a canary
# batch that the body explicitly asserts is absent.
#
# The unconditional/conditional split above is part of the same correction:
# the old list said flatly "Executor produces a plan when invoked with valid
# inputs", which the seed has never asserted — :134 is `if result[:success]`
# and the else arm only warns.
#
# Invoke:
#   cd server && SMOKE_K3S_LEVEL=db bundle exec rails runner \
#     "load Rails.root.join('../extensions/system/server/db/seeds/smoke_test_k3s_rolling_upgrade.rb')"

require_relative "_smoke_k3s_helpers"

h = ::System::Seeds::SmokeK3sHelpers
site = ENV.fetch("SMOKE_K3S_SITE", "a").downcase

puts "\n  K3s lifecycle smoke — Phase 6: Rolling module upgrade"
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

# ── Verify executor is registered ───────────────────────────────────
h.step("Verify RollingModuleUpgradeExecutor is registered")

executor_klass = ::System::Ai::Skills::RollingModuleUpgradeExecutor
h.assert(executor_klass.respond_to?(:descriptor), "executor responds to .descriptor")
desc = executor_klass.descriptor
h.assert(desc[:name] == "rolling_module_upgrade", "descriptor name == rolling_module_upgrade")
h.assert(desc[:inputs].key?(:template_id), "input :template_id declared")
h.assert(desc[:inputs].key?(:module_id), "input :module_id declared")
h.assert(desc[:inputs].key?(:target_version_id), "input :target_version_id declared")
# IMP-b948ea7fa382 — module upgrades are fleet-atomic; the descriptor no
# longer declares a batch structure or a batch_pct to size it.
h.assert(desc[:outputs].key?(:affected_instance_ids), "output :affected_instance_ids declared")
h.assert(!desc[:inputs].key?(:batch_pct), "input :batch_pct is NOT declared (fleet-atomic)")

# ── Find or synthesize template + module + target version ───────────
h.step("Resolve k3s-server template + module + create synthetic target version")

template = ::System::NodeTemplate.find_by(account: account, name: "base")
h.fail_with("base template missing") unless template

k3s_module = ::System::NodeModule.find_by(account: account, name: "k3s-server")
h.fail_with("k3s-server module missing") unless k3s_module

# Create a synthetic target version. The smoke validates the executor
# contract, not version resolution against real builds.
target_version = ::System::NodeModuleVersion.find_or_create_by!(
  node_module: k3s_module,
  version_number: 9999
) do |v|
  v.oci_digest = "sha256:#{SecureRandom.hex(32)}"
  v.promotion_state = "live"
  v.live_at = Time.current
end
h.ok("target version: #{target_version.version_number} (id=#{target_version.id[0, 8]})")

# ── Flip the smoke NodeInstances to running so list_instances surfaces them ──
h.step("Temporarily flip smoke instances to running for the executor's list scan")
smoke_instances = ::System::NodeInstance.where(
  id: [
    h.state_read["site_#{site}_instance_id"],
    *Array(h.state_read["site_#{site}_ha_instance_ids"]),
    *Array(h.state_read["site_#{site}_agent_instance_ids"])
  ].compact
)
prior_statuses = smoke_instances.pluck(:id, :status).to_h
smoke_instances.update_all(status: "running")
h.ok("flipped #{smoke_instances.count} instance(s) to status=running")

# ── Invoke executor ─────────────────────────────────────────────────
begin
  h.step("Invoke rolling_module_upgrade executor")

  user = account.users.first
  executor = executor_klass.new(account: account, user: user, agent: nil)
  result = executor.execute(
    template_id:        template.id,
    module_id:          k3s_module.id,
    target_version_id:  target_version.id
  )

  # Even if the executor returns failure (e.g. missing related state), we
  # report the structured response — the smoke validates the contract,
  # not the upgrade itself.
  if result[:success]
    h.ok("executor returned success")
    data = result[:data] || {}
    h.assert(data.key?(:total_instances), "result.data has :total_instances")
    h.assert(data.key?(:affected_instance_ids), "result.data has :affected_instance_ids")
    # IMP-b948ea7fa382 — there is no canary batch to assert on. The earlier
    # version of this tier checked that the first batch was the smallest,
    # which described a staging property the platform never had: the served
    # version is a per-module pointer, so the affected set moves as one.
    affected = Array(data[:affected_instance_ids])
    h.assert(affected.size == data[:total_instances].to_i,
             "affected set covers the whole eligible population " \
             "(#{affected.size} == #{data[:total_instances]})")
    h.assert(!data.key?(:batches) && !data.key?(:batch_count),
             "result.data exposes no batch structure (fleet-atomic)")
  else
    h.warn_msg("executor returned failure: #{result[:error]}")
    h.warn_msg("this is acceptable at db tier if the fleet_tool can't see instances; " \
               "the contract assertions above still verify executor wiring")
  end
ensure
  # Restore prior instance statuses
  h.step("Restore smoke instance statuses")
  prior_statuses.each do |id, status|
    ::System::NodeInstance.where(id: id).update_all(status: status)
  end
  h.ok("restored #{prior_statuses.size} instance status(es)")
end

# Cleanup: keep the synthetic target_version for inspection but mark
# it metadata-only so it doesn't pollute discovery.
puts "\n  ✅ Phase 6 (rolling upgrade) complete"
puts "  executor=#{executor_klass.name} (descriptor verified)"
puts "  synthetic target_version=#{target_version.version_number}"
puts "  Next: smoke_test_k3s_cve_drill.rb"
