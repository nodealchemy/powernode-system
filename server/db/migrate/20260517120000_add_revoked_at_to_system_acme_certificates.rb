# frozen_string_literal: true

# Adds `revoked_at` to system_acme_certificates so the revoke pipeline
# can stamp the revocation moment alongside the status transition.
# Until this lands, operators could see status="revoked" with no
# corresponding timestamp — confusing in audit logs and breaks the
# phase-report rubric for P2.5.7.
class AddRevokedAtToSystemAcmeCertificates < ActiveRecord::Migration[8.1]
  def change
    add_column :system_acme_certificates, :revoked_at, :datetime, null: true
    add_index  :system_acme_certificates, :revoked_at
  end
end
