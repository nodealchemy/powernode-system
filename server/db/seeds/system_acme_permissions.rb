# frozen_string_literal: true

# System ACME permissions — gate the operator-facing CRUD for ACME
# certificates + DNS provider credentials.
#
# Plan reference: Decentralized Federation §J + P2.5.

puts "Seeding system.acme.* permissions..."

system_acme_permissions = [
  # DNS provider credentials (Cloudflare API tokens, etc.)
  { resource: "system.acme_dns", action: "read",
    description: "View ACME DNS provider credentials (name + status only; never plaintext)" },
  { resource: "system.acme_dns", action: "manage",
    description: "Create, rotate, and delete ACME DNS provider credentials" },

  # ACME certificate lifecycle
  { resource: "system.acme", action: "read",
    description: "View issued ACME certificates and renewal state" },
  { resource: "system.acme", action: "issue",
    description: "Request a new ACME certificate for a domain" },
  { resource: "system.acme", action: "renew",
    description: "Trigger an out-of-band renewal of an existing certificate" },
  { resource: "system.acme", action: "revoke",
    description: "Revoke an issued certificate" },

  # CF-DNS — DNS record management on zones the ACME credential's
  # api_token can reach (same Zone:DNS:Edit scope, broader operator
  # surface: A/AAAA/CNAME/TXT/MX/SRV/NS/CAA/PTR record CRUD).
  { resource: "system.dns", action: "read",
    description: "List DNS zones and records via the ACME credential's provider API" },
  { resource: "system.dns", action: "manage",
    description: "Create, update, and delete DNS records via the ACME credential's provider API" }
]

system_acme_permissions.each do |perm|
  name = "#{perm[:resource]}.#{perm[:action]}"
  Permission.find_or_create_by!(name: name) do |p|
    p.description = perm[:description]
  end
end

puts "  - Created/verified #{system_acme_permissions.size} permissions"

# Grant the admin role everything.
admin_role = Role.find_by(name: "admin")
if admin_role
  system_acme_permissions.each do |perm|
    name = "#{perm[:resource]}.#{perm[:action]}"
    permission = Permission.find_by(name: name)
    next unless permission
    next if admin_role.permissions.exists?(id: permission.id)
    admin_role.permissions << permission
  end
  puts "  - Granted to admin role"
end
