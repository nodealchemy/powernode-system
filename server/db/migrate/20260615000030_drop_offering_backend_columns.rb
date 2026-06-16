# frozen_string_literal: true

# Phase 2 (Service Exposure Subsystem) — Step C: finish making the offering a
# pure federated facet. After Step A backfilled an Sdwan::Service per offering
# and the model dual-read proved the backend now lives on `service`, drop the
# offering's redundant backend columns and make `service_id` required. The
# model switches from dual-read to a clean `delegate … to: :service`.
#
# Safety: refuses to proceed if any offering still lacks a service (a Step-A
# backfill that was skipped — e.g. a reserved slug). Resolve those first.
class DropOfferingBackendColumns < ActiveRecord::Migration[8.1]
  TABLE = :system_federation_service_offerings

  def up
    guard_all_offerings_service_backed!

    change_column_null TABLE, :service_id, false

    remove_column TABLE, :protocol,       :string  if column_exists?(TABLE, :protocol)
    remove_column TABLE, :backend_port,   :integer if column_exists?(TABLE, :backend_port)
    remove_column TABLE, :backend_host,   :string  if column_exists?(TABLE, :backend_host)
    # backend_vip_id is a plain uuid column (the belongs_to had no DB FK); drop it directly.
    remove_column TABLE, :backend_vip_id, :uuid    if column_exists?(TABLE, :backend_vip_id)
  end

  def down
    add_column TABLE, :protocol,       :string  unless column_exists?(TABLE, :protocol)
    add_column TABLE, :backend_port,   :integer unless column_exists?(TABLE, :backend_port)
    add_column TABLE, :backend_host,   :string  unless column_exists?(TABLE, :backend_host)
    add_column TABLE, :backend_vip_id, :uuid    unless column_exists?(TABLE, :backend_vip_id)

    # Re-hydrate the columns from each offering's service so the legacy
    # dual-read/own-column path works again after a rollback.
    if defined?(::System::Federation::ServiceOffering)
      ::System::Federation::ServiceOffering.reset_column_information
      ::System::Federation::ServiceOffering.includes(:service).find_each do |offering|
        svc = offering.service
        next unless svc

        offering.update_columns(
          protocol: svc.protocol, backend_port: svc.backend_port,
          backend_host: svc.backend_host, backend_vip_id: svc.backend_vip_id
        )
      end
    end

    change_column_null TABLE, :service_id, true
  end

  private

  def guard_all_offerings_service_backed!
    return unless defined?(::System::Federation::ServiceOffering)

    ::System::Federation::ServiceOffering.reset_column_information
    orphan_count = ::System::Federation::ServiceOffering.where(service_id: nil).count
    return if orphan_count.zero?

    raise ActiveRecord::IrreversibleMigration,
          "#{orphan_count} service_offering(s) have no service_id — re-run the Step A " \
          "backfill (migration 20260615000020) or attach a service before dropping backend columns."
  end
end
