# frozen_string_literal: true

# Adds the `sdwan.ipfix.ingest` permission for sidecar collectors that
# POST flow records to the platform's ingest endpoint. Distinct from
# `sdwan.ipfix.read` (already seeded in 20260510020001) so operators can
# grant ingest-only credentials to vector/fluent-bit service accounts
# without exposing the full collector read surface.
#
# Phase O6 follow-up of the OVS+OVN dual-profile networking roadmap.
class SeedSdwanIpfixIngestPermission < ActiveRecord::Migration[8.1]
  PERMISSIONS = [
    { name: "sdwan.ipfix.ingest", category: "resource", action: "ingest", resource: "ipfix",
      description: "Submit IPFIX flow records to the platform's ingest endpoint (sidecar collector role)" }
  ].freeze

  def up
    return unless defined?(::Permission)

    PERMISSIONS.each do |attrs|
      ::Permission.find_or_create_by!(name: attrs[:name]) do |p|
        p.category    = attrs[:category]    if p.respond_to?(:category=)
        p.action      = attrs[:action]      if p.respond_to?(:action=)
        p.resource    = attrs[:resource]    if p.respond_to?(:resource=)
        p.description = attrs[:description] if p.respond_to?(:description=)
      end
    end
  end

  def down
    return unless defined?(::Permission)

    ::Permission.where(name: PERMISSIONS.map { |p| p[:name] }).delete_all
  end
end
