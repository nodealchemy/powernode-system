# frozen_string_literal: true

# Sdwan::OvnDeployment — represents the central OVN control plane for a
# single account. One row per account: holds the NB/SB endpoints the
# heavyweight hosts' `ovn-controller` daemons connect to, plus an
# advisory pointer to whichever host runs `ovn-northd`.
#
# The platform's Rails control plane writes desired logical-network
# state (Sdwan::OvnLogicalSwitch + Sdwan::OvnLogicalSwitchPort rows)
# and the Sdwan::OvnCompiler renders that state into an `ovn-nbctl`
# command plan that an executor (or the operator) can replay against
# the NB DB.
#
# Lifecycle (AASM column: status):
#   pending        → row created; daemons not running yet
#   bootstrapping  → endpoints set; agents are bringing daemons up
#   active         → the NB DB itself was positively observed: a chassis
#                    replayed the full compiled plan against it, or the
#                    control-plane NbProbe got a list_dbs reply naming
#                    OVN_Northbound at the endpoint. That is ALL it
#                    certifies — neither northd's NB→SB reconciliation
#                    nor any ovn-controller's SB subscription is directly
#                    measured yet (Sdwan::Ovn::DeploymentReconciler)
#   degraded       → a MEASURED negative stands: a failed/partial chassis
#                    replay, or the probe lost an endpoint it had
#                    confirmed — readopt back to active when the failing
#                    source itself recovers
#
# Phase O3 of the OVS+OVN dual-profile roadmap (heavyweight track).
module Sdwan
  class OvnDeployment < ApplicationRecord
    include AASM

    self.table_name = "system_sdwan_ovn_deployments"

    STATES = %w[pending bootstrapping active degraded].freeze

    # OVN's standard ports — used as defaults when callers don't pass
    # a full `tcp:host:port` literal. The compiler does not depend on
    # these (it consumes whatever is on the row); they're here so
    # operator-facing tools can pre-fill the field.
    DEFAULT_NB_PORT = 6641
    DEFAULT_SB_PORT = 6642

    # Loose validation — accepts `tcp:`, `ssl:`, `unix:` prefixes plus
    # comma-separated cluster lists. We rely on OVN's own parser to
    # reject malformed values at apply time; this regex catches the
    # common typos (missing scheme, raw hostname).
    ENDPOINT_FORMAT = %r{\A(tcp|ssl|unix):\S+\z}.freeze

    belongs_to :account

    has_many :logical_switches,
             class_name: "Sdwan::OvnLogicalSwitch",
             foreign_key: :sdwan_ovn_deployment_id,
             dependent: :destroy,
             inverse_of: :deployment

    # One deployment per account in O3 — multi-deployment-per-account
    # is a future expansion (test/staging/prod envs sharing one Rails
    # account). The unique index on account_id enforces this at the DB.
    validates :account_id, uniqueness: true
    validates :status, inclusion: { in: STATES }

    # Endpoints are required once we leave `pending` — agents can't
    # bring daemons up without knowing where the DBs live, and the
    # compiler consumers (executor, operator UI) need them to reach
    # the NB DB. We allow `pending` rows with blank endpoints so an
    # operator can stub a row and fill in the connection later.
    validates :nb_db_endpoint, :sb_db_endpoint,
              presence: true,
              if: :endpoints_required?

    # Format validation runs whenever an endpoint value is present —
    # even in `pending` — so an operator can't stub a row with garbage
    # and have it bypass the format check until later.
    validates :nb_db_endpoint, format: { with: ENDPOINT_FORMAT },
                               if: -> { nb_db_endpoint.present? }
    validates :sb_db_endpoint, format: { with: ENDPOINT_FORMAT },
                               if: -> { sb_db_endpoint.present? }

    # The states the TopologyCompiler serves chassis config for. Everything
    # except pending: bootstrapping is BY DEFINITION "agents are bringing
    # daemons up" (they need the config to do that), and degraded must stay
    # served because recovery evidence can only come from a served chassis.
    # Pending is the one state whose endpoints may be blank, so there is
    # nothing an agent could act on. (IMP-57e9a90598ee — the previous
    # active-only gate structurally prevented its own opener: no deployment
    # could ever produce the observation required to become active.)
    SERVABLE_STATUSES = %w[bootstrapping active degraded].freeze

    scope :active,        -> { where(status: "active") }
    scope :bootstrapping, -> { where(status: "bootstrapping") }
    scope :pending,       -> { where(status: "pending") }
    scope :degraded,      -> { where(status: "degraded") }
    scope :servable,      -> { where(status: SERVABLE_STATUSES) }
    scope :for_account,   ->(account) { where(account_id: account.id) }

    aasm column: :status, whiny_transitions: false do
      state :pending, initial: true
      state :bootstrapping
      state :active
      state :degraded

      event :start_bootstrap do
        transitions from: %i[pending bootstrapping], to: :bootstrapping
        before { self.bootstrapped_at ||= Time.current }
      end

      event :mark_active do
        transitions from: %i[bootstrapping degraded active], to: :active
        before do
          self.activated_at ||= Time.current
          self.degraded_at = nil
        end
      end

      event :mark_degraded do
        transitions from: %i[active degraded], to: :degraded
        before { self.degraded_at ||= Time.current }
      end

      event :readopt do
        # Recover a deployment that an external observer reports as
        # healthy after we'd marked it degraded. Mirrors the readopt
        # path on Sdwan::HostBridge / Sdwan::HostVrfAssignment.
        transitions from: %i[degraded pending], to: :active
        before do
          self.activated_at ||= Time.current
          self.degraded_at = nil
        end
      end
    end

    private

    # Endpoints become required the moment we leave `pending` — at
    # that point an agent or executor will try to use them, so blank
    # values can no longer be tolerated.
    def endpoints_required?
      status.present? && status != "pending"
    end
  end
end
