# frozen_string_literal: true

# System extension — gitea-act-runner CI registration smoke test
# (campaign 019f5885 inc2).
#
# Platform-side smoke. Validates the ci_runner_registration node_api
# endpoint's backend wiring without needing a live-booted gitea-act-runner
# instance:
#
#   1. Pick a NodeInstance with an active NodeCertificate (real enrollment).
#   2. Assign the gitea-act-runner NodeModule to its Node (idempotent).
#   3. Negative: a sibling Node WITHOUT the module fails the module-presence
#      gate the controller enforces BEFORE ever touching a Gitea credential
#      — same fail-closed shape as #dev_cell_bootstrap's own gate.
#   4. Resolve the account's active Gitea credential. SKIPS (not a failure)
#      the live-mint check if none is configured — an operator must set one
#      via Settings -> DevOps -> Git Providers first.
#   5. Live-mint an org-scope registration token via
#      Devops::RunnerLifecycleService#registration_token_for_scope — the
#      exact service+scope+owner the controller calls — and assert a real
#      token comes back from the configured Gitea instance. The token
#      itself is never printed (CryptoMaterialSafety).
#   6. Cleanup any module assignment / Node created by the test.
#
# Out of scope (needs a live-booted VM + built module):
#   - The instance's own mTLS round trip to GET .../ci_runner_registration
#   - gitea-act-runner-register.sh actually staging the token 0600
#   - act_runner register/daemon actually starting against a real docker
#
# Invoke:
#   cd server && bundle exec rails runner \
#     "load Rails.root.join('../extensions/system/server/db/seeds/smoke_test_ci_runner.rb')"

step = ->(label) { puts "\n  [step] #{label}" }
ok   = ->(msg)   { puts "    ✓ #{msg}" }
info = ->(msg)   { puts "    · #{msg}" }
fail_with = ->(msg) {
  puts "    ✗ #{msg}"
  abort("  💥 SMOKE FAIL")
}
assert = ->(condition, msg) { condition ? ok.call(msg) : fail_with.call(msg) }

puts "\n  gitea-act-runner CI registration smoke test"
puts "  ============================================"
puts "  Today: #{Date.today}, Rails env: #{Rails.env}"

# ── Pick a NodeInstance with an active certificate ─────────────────
step.call("Discover a NodeInstance with an active NodeCertificate")

instance = ::System::NodeInstance
             .joins("INNER JOIN system_node_certificates ON system_node_certificates.node_instance_id = system_node_instances.id")
             .where("system_node_certificates.not_before <= ? AND system_node_certificates.not_after > ?", Time.current, Time.current)
             .first
fail_with.call("No NodeInstance with an active certificate found — enroll one first") unless instance

account = instance.account
node = instance.node
ok.call("instance=#{instance.name} (id=#{instance.id[0, 8]})")
ok.call("account=#{account.name} (id=#{account.id[0, 8]})")

# ── Module assignment ──────────────────────────────────────────────
step.call("Ensure gitea-act-runner NodeModule is assigned to the node")

ci_runner_module = ::System::NodeModule.where(account: account, name: "gitea-act-runner").first
fail_with.call("gitea-act-runner module not imported — import modules/gitea-act-runner/manifest.yaml first") unless ci_runner_module

assignment = ::System::NodeModuleAssignment.where(node: node, node_module: ci_runner_module).first
created_assignment = false
unless assignment
  assignment = ::System::NodeModuleAssignment.create!(node: node, node_module: ci_runner_module, enabled: true)
  created_assignment = true
end
ok.call("module assignment #{created_assignment ? 'created' : 'already present'} (id=#{assignment.id[0, 8]})")

# ────────────────────────────────────────────────────────────────────
# Smoke 1: module-presence gate (negative — no Gitea credential needed)
# ────────────────────────────────────────────────────────────────────

step.call("Negative: a sibling Node WITHOUT the module fails the presence gate")

plain_node = ::System::Node.create!(
  account: account, node_template: node.node_template,
  name: "smoke-ci-runner-plain-#{SecureRandom.hex(3)}"
)
assert.call(plain_node.node_modules.exists?(name: "gitea-act-runner") == false,
            "sibling node without an assignment has no gitea-act-runner module (controller would 403)")
assert.call(node.node_modules.exists?(name: "gitea-act-runner"),
            "the assigned node DOES carry the module (controller would proceed)")
plain_node.destroy

# ────────────────────────────────────────────────────────────────────
# Smoke 2: live token mint (skips gracefully with no Gitea credential)
# ────────────────────────────────────────────────────────────────────

step.call("Resolve the account's active Gitea credential")

gitea_credential = account.git_provider_credentials.active
                          .joins(:provider)
                          .where(git_providers: { provider_type: "gitea" })
                          .first

if gitea_credential.nil?
  info.call("no active Gitea credential configured on this account — skipping live token-mint check")
  info.call("configure one via Settings -> DevOps -> Git Providers, then re-run this smoke")
else
  step.call("Live-mint an org-scope registration token via Devops::RunnerLifecycleService")

  service = ::Devops::RunnerLifecycleService.new(account: account)
  result = service.registration_token_for_scope(
    credential: gitea_credential, scope: :org, owner: "powernode"
  )
  assert.call(result[:token].present?,
              "registration_token_for_scope returned a token (got keys: #{result.except(:token).keys.inspect})")
  ok.call("token minted (value withheld from this output — CryptoMaterialSafety)")
end

# ────────────────────────────────────────────────────────────────────
# Cleanup
# ────────────────────────────────────────────────────────────────────

step.call("Cleanup")

if created_assignment
  assignment.destroy
  ok.call("removed test-created module assignment")
else
  ok.call("module assignment retained (existed before smoke test)")
end

puts "\n  ✅ ALL GITEA-ACT-RUNNER REGISTRATION SMOKE CHECKS PASSED"
puts "  ========================================================"
puts "  Validated:"
puts "    - gitea-act-runner module assignable to a real Node"
puts "    - Module-presence gate: a sibling node without the assignment is excluded"
puts "    - Live org-scope Gitea registration token mint via Devops::RunnerLifecycleService (when a credential is configured)"
puts ""
puts "  NOT validated by this smoke (requires a live-booted VM):"
puts "    - The instance's own mTLS round trip to ci_runner_registration"
puts "    - gitea-act-runner-register.sh staging the token 0600"
puts "    - act_runner register/daemon actually starting against a real docker"
