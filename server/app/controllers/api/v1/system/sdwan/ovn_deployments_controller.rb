# frozen_string_literal: true

# Operator-facing read API for Sdwan::OvnDeployment + nested logical
# switches + ports. Read-only — composition happens through the
# SdwanOvnComposeTopologyExecutor AI skill or the
# system_sdwan_create_ovn_deployment / _create_ovn_logical_switch /
# _create_ovn_logical_switch_port MCP actions.
#
# OvnDeployment is per-account (DB-unique on account_id), so #index
# returns at most one row. The interesting endpoint is #show: it folds
# the full topology — deployment + switches + each switch's ports —
# into one payload, plus the compiled ovn-nbctl plan an operator can
# replay against the NB DB. Heavy reads are still cheap because OVN
# topologies are bounded (50 switches × 250 ports per the AI skill's
# limits).
#
# Phase O6 of the OVS+OVN dual-profile networking roadmap.
module Api
  module V1
    module System
      module Sdwan
        class OvnDeploymentsController < ::Api::V1::System::BaseController
          before_action :set_account
          before_action :set_deployment, only: %i[show]

          def index
            require_permission("sdwan.ovn.read")

            deployment = ::Sdwan::OvnDeployment.for_account(@account).first

            render_success(
              ovn_deployments: deployment ? [ serialize_summary(deployment) ] : [],
              count: deployment ? 1 : 0
            )
          end

          def show
            require_permission("sdwan.ovn.read")

            switches = @deployment.logical_switches
                                  .includes(:ports)
                                  .order(:name)
                                  .to_a

            render_success(
              ovn_deployment: serialize_deployment_full(@deployment, switches: switches),
              compiled_plan: safe_compile(@deployment)
            )
          end

          private

          def set_deployment
            @deployment = ::Sdwan::OvnDeployment.where(account_id: @account.id)
                                                .find(params[:id])
          rescue ActiveRecord::RecordNotFound
            render_not_found("SDWAN OVN Deployment")
          end

          # Cheap summary used by #index — just counts, no nested traversal,
          # so listing scales even when an account grows hundreds of switches.
          def serialize_summary(d)
            {
              id: d.id,
              status: d.status,
              nb_db_endpoint: d.nb_db_endpoint,
              sb_db_endpoint: d.sb_db_endpoint,
              northd_host: d.northd_host,
              switch_count: d.logical_switches.compilable.count,
              port_count: ::Sdwan::OvnLogicalSwitchPort
                            .joins(:logical_switch)
                            .where(sdwan_ovn_logical_switches: { sdwan_ovn_deployment_id: d.id })
                            .compilable
                            .count,
              bootstrapped_at: d.bootstrapped_at&.iso8601,
              activated_at: d.activated_at&.iso8601,
              degraded_at: d.degraded_at&.iso8601
            }
          end

          def serialize_deployment_full(d, switches:)
            serialize_summary(d).merge(
              created_at: d.created_at.iso8601,
              updated_at: d.updated_at.iso8601,
              logical_switches: switches.map { |s| serialize_switch(s) }
            )
          end

          def serialize_switch(s)
            {
              id: s.id,
              name: s.name,
              cidr: s.cidr,
              state: s.state,
              activated_at: s.activated_at&.iso8601,
              removed_at: s.removed_at&.iso8601,
              ports: s.ports.sort_by(&:name).map { |p| serialize_port(p) }
            }
          end

          def serialize_port(p)
            {
              id: p.id,
              name: p.name,
              kind: p.kind,
              state: p.state,
              mac: p.mac,
              addresses: Array(p.addresses),
              host_node_instance_id: p.host_node_instance_id,
              activated_at: p.activated_at&.iso8601,
              removed_at: p.removed_at&.iso8601
            }
          end

          # Compiler errors shouldn't break the show endpoint — the row
          # might still be useful to inspect even when compilation can't
          # run (e.g., transient DB state mid-bootstrap).
          def safe_compile(deployment)
            ::Sdwan::OvnCompiler.compile_for_deployment(deployment)
          rescue StandardError => e
            Rails.logger.warn("[OvnDeploymentsController] compile failed for #{deployment.id}: #{e.message}")
            { error: e.message }
          end
        end
      end
    end
  end
end
