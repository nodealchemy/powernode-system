# frozen_string_literal: true

# Smoke test: end-to-end ACME cert issuance against Let's Encrypt staging
# (or prod via env override) using the platform's bundled powernode-acme
# Go binary + an operator-configured DNS provider credential.
#
# Run via:
#   cd server && bundle exec rails runner \
#     "load Rails.root.join('../extensions/system/server/db/seeds/smoke_test_acme_issuance.rb')"
#
# Required env vars:
#   ACME_DOMAIN       - the domain to issue for (e.g. dev.powernode.net)
#   ACME_EMAIL        - ACME account email (LE registration contact)
#   ACME_DNS_CRED_ID  - System::AcmeDnsCredential.id (or set ACME_DNS_CRED_NAME)
#
# Optional env vars:
#   ACME_DNS_CRED_NAME    - alternative lookup by name (resolved within account)
#   ACME_ISSUER           - "letsencrypt-staging" (default) | "letsencrypt-prod"
#   ACME_ACCOUNT_ID       - target account id (default: first account)
#   ACME_SANS             - comma-separated additional SANs
#
# Plan reference: Decentralized Federation §J + P2.5.7.

require "uri"

domain    = ENV.fetch("ACME_DOMAIN")
email     = ENV.fetch("ACME_EMAIL")
issuer    = ENV.fetch("ACME_ISSUER", "letsencrypt-staging")
sans_raw  = ENV["ACME_SANS"].to_s
sans      = sans_raw.split(",").map(&:strip).reject(&:empty?)

account = if ENV["ACME_ACCOUNT_ID"]
            Account.find(ENV["ACME_ACCOUNT_ID"])
else
            Account.order(:created_at).first
end
abort "❌ No account found. Set ACME_ACCOUNT_ID=..." unless account

dns_cred = if ENV["ACME_DNS_CRED_ID"].present?
             ::System::AcmeDnsCredential.where(account: account).find(ENV["ACME_DNS_CRED_ID"])
elsif ENV["ACME_DNS_CRED_NAME"].present?
             ::System::AcmeDnsCredential.where(account: account, name: ENV["ACME_DNS_CRED_NAME"]).first
else
             ::System::AcmeDnsCredential.where(account: account).order(:created_at).first
end
abort "❌ No DNS credential found. Configure one at /app/system/acme first." unless dns_cred

puts "─" * 70
puts "ACME issuance smoke test"
puts "─" * 70
puts "  account     : #{account.id} (#{account.name})"
puts "  domain      : #{domain}"
puts "  SANs        : #{sans.any? ? sans.join(", ") : "(none)"}"
puts "  email       : #{email}"
puts "  issuer      : #{issuer}"
puts "  DNS cred    : #{dns_cred.name} (#{dns_cred.provider}, status=#{dns_cred.status})"
puts "  binary      : #{::Acme::LegoClient.new.send(:resolve_binary_path)}"
puts "─" * 70

if dns_cred.status != "valid"
  puts "⚠️  DNS credential status is '#{dns_cred.status}', not 'valid'. " \
       "Run 'Test connectivity' on the credential first."
end

cert = ::System::AcmeCertificate.create!(
  account: account,
  common_name: domain,
  sans: sans,
  dns_credential: dns_cred,
  issuer: issuer,
  challenge_type: "dns-01",
  status: "pending",
  traefik_resolver_name: "letsencrypt",
  metadata: { "acme_email" => email, "smoke_test_at" => Time.current.iso8601 }
)
puts "✓ Created AcmeCertificate row id=#{cert.id}"
puts "  Calling Acme::CertificateManager.issue! — this may take 60-180s " \
     "(DNS propagation + LE polling)..."
puts

start = Time.current
result = ::Acme::CertificateManager.issue!(certificate: cert)
elapsed = (Time.current - start).round(1)

puts
puts "─" * 70
puts "Issuance complete in #{elapsed}s"
puts "─" * 70
if result.ok?
  cert.reload
  puts "✓ Success"
  puts "  status         : #{cert.status}"
  puts "  issued_at      : #{cert.issued_at}"
  puts "  expires_at     : #{cert.expires_at}"
  puts "  vault_path_cert: #{cert.vault_path_certificate}"
  puts "  vault_path_key : #{cert.vault_path_private_key}"
  puts
  puts "Next: inspect the cert by fetching from Vault, or wire Traefik via"
  puts "Acme::TraefikConfigWriter to serve it on the platform's :443."
else
  puts "❌ Failed: #{result.error}"
  cert.reload
  puts "  cert.status      : #{cert.status}"
  puts "  last_renewal_err : #{cert.last_renewal_error}" if cert.respond_to?(:last_renewal_error)
end
