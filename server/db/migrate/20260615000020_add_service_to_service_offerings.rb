# frozen_string_literal: true

# Phase 2 (Service Exposure Subsystem) — Step A: make a federated
# ServiceOffering a *facet* of a first-class Sdwan::Service rather than an
# independent backend owner.
#
# This migration is purely ADDITIVE + backfill:
#   1. add a nullable `service_id` FK on system_federation_service_offerings,
#   2. backfill one Sdwan::Service per existing offering (reusing an existing
#      same-slug service in the account if one already exists — they ARE the
#      same service), copying the offering's backend (vip/host/port/protocol).
#
# The offering keeps its own backend_* / protocol columns for now — the model
# dual-reads (prefers `service`, falls back to its own columns), so reads work
# whether or not a service is attached. Step C drops the redundant columns once
# every offering is service-backed.
#
# Backfill is per-row guarded: an offering whose slug can't be a valid
# Sdwan::Service (e.g. a reserved slug) is left with service_id = NULL and keeps
# serving from its own columns via the dual-read. Idempotent: re-running skips
# offerings that already have a service_id.
class AddServiceToServiceOfferings < ActiveRecord::Migration[8.1]
  def up
    unless column_exists?(:system_federation_service_offerings, :service_id)
      add_reference :system_federation_service_offerings, :service,
                    type: :uuid, null: true,
                    foreign_key: { to_table: :sdwan_services }
    end

    # A service-backed offering sources its backend from #service and leaves
    # its own backend columns NULL (the model dual-reads). Relax the DB NOT NULL
    # so that state is representable now; Step C drops the columns entirely.
    change_column_null :system_federation_service_offerings, :protocol, true
    change_column_null :system_federation_service_offerings, :backend_port, true

    backfill_services!
  end

  def down
    if foreign_key_exists?(:system_federation_service_offerings, column: :service_id)
      remove_foreign_key :system_federation_service_offerings, column: :service_id
    end
    remove_reference :system_federation_service_offerings, :service if column_exists?(:system_federation_service_offerings, :service_id)
    # Restore NOT NULL only if no service-backed (NULL-backend) rows exist.
    if ::System::Federation::ServiceOffering.where(protocol: nil).none?
      change_column_null :system_federation_service_offerings, :protocol, false
    end
    if ::System::Federation::ServiceOffering.where(backend_port: nil).none?
      change_column_null :system_federation_service_offerings, :backend_port, false
    end
  end

  private

  def backfill_services!
    return unless defined?(::System::Federation::ServiceOffering) && defined?(::Sdwan::Service)

    ::System::Federation::ServiceOffering.reset_column_information
    ::System::Federation::ServiceOffering.where(service_id: nil).find_each do |offering|
      service = find_or_build_service_for(offering)
      next unless service&.persisted?

      offering.update_column(:service_id, service.id)
    rescue StandardError => e
      say "  skip offering #{offering.id} (#{offering.slug}): #{e.class}: #{e.message}"
    end
  end

  # Reuse an existing same-slug service in the account (the offering is a facet
  # of it), else create one from the offering's backend snapshot.
  def find_or_build_service_for(offering)
    existing = ::Sdwan::Service.find_by(account_id: offering.account_id, slug: offering.slug)
    return existing if existing

    service = ::Sdwan::Service.new(
      account_id:     offering.account_id,
      slug:           offering.slug,
      name:           offering.name,
      protocol:       offering.read_attribute(:protocol),
      backend_vip_id: offering.read_attribute(:backend_vip_id),
      backend_host:   offering.read_attribute(:backend_host),
      backend_port:   offering.read_attribute(:backend_port),
      status:         "active"
    )
    return service if service.save

    say "  could not backfill service for offering #{offering.id} (#{offering.slug}): " \
        "#{service.errors.full_messages.join('; ')}"
    nil
  end
end
