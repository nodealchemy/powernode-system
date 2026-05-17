# frozen_string_literal: true

# P4.6 — system_federation_grants.grantor_user_id was NOT NULL
# under the assumption that every grant traces back to a specific
# user-initiated action. Service-subscription grants (issued by
# Federation::ServiceCatalogService when a remote peer subscribes
# to an offering) have no specific user grantor — operator
# authorization is implicit via the catalog itself.
#
# Relax to nullable; the model side adds `optional: true` on the
# belongs_to. Existing rows are unaffected.
#
# Plan reference: Decentralized Federation §L + P4.6.2.
class RelaxGrantorUserIdOnFederationGrants < ActiveRecord::Migration[8.0]
  def change
    change_column_null :system_federation_grants, :grantor_user_id, true
  end
end
