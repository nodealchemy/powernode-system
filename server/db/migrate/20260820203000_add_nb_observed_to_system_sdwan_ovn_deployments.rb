# frozen_string_literal: true

# IMP-57e9a90598ee — durable observation state for the OVN activation lane.
#
# nb_observed holds what the platform has actually MEASURED about the
# deployment's NB DB, written only by Sdwan::Ovn::DeploymentReconciler via
# update_columns (never touching updated_at — TopologyCompiler's NB-plan cache
# key folds updated_at, so an observation stamp must not invalidate the
# compiled plan):
#
#   "last"    => the most recent meaningful chassis replay observation
#   "failing" => per-source unresolved failures, keyed by chassis instance id
#                or "nb_probe"; an entry clears only when ITS source next
#                succeeds (mirrors the agent's per-subsystem outcome rule)
class AddNbObservedToSystemSdwanOvnDeployments < ActiveRecord::Migration[8.0]
  def change
    add_column :system_sdwan_ovn_deployments, :nb_observed, :jsonb, default: {}, null: false
  end
end
