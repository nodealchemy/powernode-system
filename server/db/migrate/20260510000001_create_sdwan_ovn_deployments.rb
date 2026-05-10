# frozen_string_literal: true

# Sdwan::OvnDeployment — per-account control-plane deployment of OVN
# (Open Virtual Network). One row holds the endpoints of the central
# Northbound and Southbound databases plus a hint about which host runs
# `ovn-northd`. The on-host `ovn-controller` daemons read these
# endpoints from their per-host config (delivered via the agent's
# OvnControl payload) and connect to the SB DB; the platform's Rails
# control plane writes the desired logical-network state to the NB DB.
#
# Lifecycle states (AASM):
#   pending       → row created; no central daemons exist yet
#   bootstrapping → endpoints set; agents are bringing daemons up
#   active        → northd is reconciling NB→SB and ≥1 ovn-controller
#                   has subscribed to the SB DB
#   degraded      → at least one health probe failed (NB or SB unreach,
#                   northd offline) — readopt back to active when the
#                   probe recovers
#
# Phase O3 of the OVS+OVN dual-profile roadmap (heavyweight track).
class CreateSdwanOvnDeployments < ActiveRecord::Migration[8.1]
  def change
    create_table :sdwan_ovn_deployments, id: :uuid do |t|
      t.references :account, null: false, type: :uuid, foreign_key: true,
                   index: { unique: true,
                            name: "index_sdwan_ovn_deployments_on_account" }

      # Wire endpoints in OVN's standard ovn-nbctl/ovn-sbctl format —
      # `tcp:HOST:PORT` for plain TCP, `ssl:HOST:PORT` for OVN's
      # OpenSSL-secured channel. Defaults are 6641 (NB) / 6642 (SB).
      # Both fields tolerate comma-separated lists for clustered DBs.
      t.string :nb_db_endpoint
      t.string :sb_db_endpoint

      # Informational — which host the operator placed `ovn-northd` on.
      # northd talks to NB+SB only; placement is a deployment choice,
      # not a hard binding, so this is advisory and used for operator
      # display + drift detection rather than for routing decisions.
      t.string :northd_host

      t.string :status, null: false, default: "pending"

      t.jsonb :settings, default: {}, null: false

      t.datetime :bootstrapped_at
      t.datetime :activated_at
      t.datetime :degraded_at

      t.timestamps
    end

    add_index :sdwan_ovn_deployments, :status

    add_check_constraint :sdwan_ovn_deployments,
                         "status IN ('pending','bootstrapping','active','degraded')",
                         name: "sdwan_ovn_deployments_status_check"
  end
end
