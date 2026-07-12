# frozen_string_literal: true

# bootstrap-first-admin.rb — headless first-admin bootstrap for the hub.
#
# Invoked by rails-start.sh (via `rails runner`) on first boot, AFTER
# db:migrate and BEFORE db:seed: the baseline seeds (AI provider catalog,
# global platform agents, system-extension agents) all resolve the admin
# account + user, and a self-contained hub has no operator to click through
# the setup wizard first. This is the headless equivalent of
# POST /api/v1/setup/admin — one shared definition via Setup::FirstAdminService
# (which also ensures roles + the system Worker).
#
# Idempotent: skips when any user already exists. The generated password is
# validated against the platform password policy and written ONLY to
# $ADMIN_CREDS (mode 0600, durable store) for operator retrieval — it is
# never echoed or logged.

require "securerandom"
require "json"

if User.exists?
  puts "[bootstrap-first-admin] a user already exists — skipping"
else
  creds_path = ENV.fetch("ADMIN_CREDS", "/etc/powernode/admin-credentials.json")

  # base58 + "!X9" guarantees the special/upper/digit classes; the policy
  # validator loop covers the rest (lowercase presence, no repeat/sequence
  # patterns, entropy) — retry until a candidate passes.
  password = nil
  10.times do
    candidate = "#{SecureRandom.base58(20)}!X9"
    if Security::PasswordStrengthService.validate_password(candidate)[:valid]
      password = candidate
      break
    end
  end
  raise "bootstrap-first-admin: could not generate a policy-compliant password" unless password

  result = Setup::FirstAdminService.call(
    email: "admin@powernode.org",
    password: password,
    name: "Powernode Admin",
    account_name: "Powernode Admin"
  )

  File.write(
    creds_path,
    JSON.pretty_generate(
      email: result.user.email,
      password: password,
      generated_at: Time.current.iso8601,
      note: "First-admin credentials, generated at hub first boot. Stored mode 0600 for operator retrieval."
    ),
    perm: 0o600
  )
  puts "[bootstrap-first-admin] first admin bootstrapped (#{result.user.email}); credentials at #{creds_path}"
end
