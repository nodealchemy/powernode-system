# frozen_string_literal: true

# IMP-57e9a90598ee — operator surfacing for the OVN activation lane.
#
# Sdwan::Ovn::DeploymentReconciler owns the transitions (it runs at heartbeat
# ingest, where the observations are); this sensor owns making the resulting
# states VISIBLE on the fleet tick. It is strictly read-side: transitioning a
# deployment from a tick would be a "timer elapsed" pseudo-oracle, which is
# the exact fiction the reconciler exists to end.
#
# TWO kinds, one disposition (surface to the operator, no auto-action):
#
#   system.sdwan_ovn_deployment_degraded  — a MEASURED negative stands
#                                           unresolved (see the failing map
#                                           in nb_observed for who measured
#                                           it and what they saw).
#
#   system.sdwan_ovn_activation_stalled   — the deployment has sat outside
#                                           "active" past the grace window.
#                                           The payload's `reason` says which
#                                           precondition is missing, because
#                                           each has a different owner:
#                                           endpoints_missing (operator),
#                                           no_heavyweight_chassis (operator
#                                           — promote a host or fix the
#                                           classifier's inputs),
#                                           replay_failing (the NB DB or the
#                                           chassis path), not_observed
#                                           (nothing measurable yet — e.g.
#                                           an ssl: endpoint the probe
#                                           cannot speak and no chassis
#                                           replay yet).
#
# Both bind to system.sdwan_ovn_deployment_investigate — notify_and_proceed,
# no applier by design (there is no safe blind remediation for OVN control
# infrastructure the platform does not provision), and therefore listed in
# RemediationValidator::NON_REMEDIATING_ACTION_CATEGORIES.
module System
  module Fleet
    module Sensors
      class SdwanOvnDeploymentHealthSensor < BaseSensor
        # How long a deployment may sit non-active before the stall is
        # surfaced. Bootstrap legitimately takes minutes (operator stands up
        # daemons, chassis converge); alarming instantly would just train
        # operators to ignore the signal.
        DEFAULT_STALL_AFTER_SECONDS = 1800 # 30 minutes

        # Same setting namespace as Sdwan::Ovn::NbProbe — one knob family
        # for the lane.
        SETTING_PREFIX = "system.sdwan.ovn"
        ACCOUNT_SETTING_PREFIX = "sdwan_ovn"

        def sense
          return [] unless defined?(::Sdwan::OvnDeployment)

          deployment = ::Sdwan::OvnDeployment.for_account(account).first
          return [] if deployment.nil?

          case deployment.status
          when "degraded"
            [ degraded_signal(deployment) ]
          when "pending", "bootstrapping"
            Array(stalled_signal(deployment))
          else
            []
          end
        end

        private

        def stall_after_seconds
          @stall_after_seconds ||= begin
            raw = account.settings&.dig("#{ACCOUNT_SETTING_PREFIX}_stall_after_seconds").presence ||
                  ::SiteSetting.get("#{SETTING_PREFIX}.stall_after_seconds")
            value = raw.to_i
            value.positive? ? value : DEFAULT_STALL_AFTER_SECONDS
          end
        end

        def degraded_signal(deployment)
          signal(
            kind: "system.sdwan_ovn_deployment_degraded",
            severity: :high,
            payload: {
              "deployment_id"  => deployment.id,
              "nb_db_endpoint" => deployment.nb_db_endpoint,
              "degraded_at"    => deployment.degraded_at&.iso8601,
              "failing"        => (deployment.nb_observed || {}).fetch("failing", {}),
              # No automated remediation: the failing component is OVN
              # control infrastructure the platform does not stand up.
              "remediation_action" => nil
            },
            fingerprint: "sdwan_ovn_deployment_degraded:#{deployment.id}"
          )
        end

        def stalled_signal(deployment)
          anchor = deployment.bootstrapped_at || deployment.created_at
          return nil if anchor.nil? || anchor > stall_after_seconds.seconds.ago

          signal(
            kind: "system.sdwan_ovn_activation_stalled",
            severity: :medium,
            payload: {
              "deployment_id"   => deployment.id,
              "status"          => deployment.status,
              "nb_db_endpoint"  => deployment.nb_db_endpoint,
              "stalled_since"   => anchor.iso8601,
              "reason"          => stall_reason(deployment),
              "failing"         => (deployment.nb_observed || {}).fetch("failing", {}),
              "remediation_action" => nil
            },
            fingerprint: "sdwan_ovn_activation_stalled:#{deployment.id}"
          )
        end

        # Ordered by ownership: config gaps an operator must fill come before
        # measured failures, which come before "nothing measurable yet".
        def stall_reason(deployment)
          if deployment.nb_db_endpoint.blank? || deployment.sb_db_endpoint.blank?
            return "endpoints_missing"
          end
          if (deployment.nb_observed || {}).fetch("failing", {}).present?
            return "replay_failing"
          end
          unless ::System::NodeInstance.heavyweight_profile
                                       .joins(:node)
                                       .where(system_nodes: { account_id: account.id })
                                       .exists?
            return "no_heavyweight_chassis"
          end

          "not_observed"
        end
      end
    end
  end
end
