# frozen_string_literal: true

module Api
  module V1
    module System
      # Operator-facing read API for CVE exposures. Until now CVE data was
      # worker/MCP-only (worker_api/cve_controller ingests the feed,
      # worker_api/cve_responder_controller runs the autonomy tick) — there
      # was no operator surface to list the exposures those jobs produce, so
      # the frontend couldn't render the fleet's CVE risk posture.
      #
      # A System::CveExposure has no direct account_id; it scopes to the
      # operator's account through node_module_version → node_module, whose
      # account_id is the source of truth. This is the same join the CVE
      # Responder's CvePublishedSensor uses to scope exposures per account
      # (app/services/system/cve_ops/sensors/cve_published_sensor.rb).
      class CveExposuresController < BaseController
        before_action :set_exposure, only: [ :show ]

        # GET /api/v1/system/cve_exposures
        # Filters (query params):
        #   severity — one of System::Cve::SEVERITIES (filters on the joined CVE)
        #   state    — one of System::CveExposure::STATES (alias: `status`)
        def index
          require_permission("system.cve.read")

          exposures = account_exposures
          exposures = apply_filters(exposures)
          exposures = paginate(exposures.order(detected_at: :desc))

          render_success(
            cve_exposures: exposures.map { |e| serialize_exposure(e) },
            meta: pagination_meta
          )
        end

        # GET /api/v1/system/cve_exposures/:id
        def show
          require_permission("system.cve.read")
          render_success(cve_exposure: serialize_exposure(@exposure))
        end

        private

        # Base account-scoped relation. The join to node_module is what
        # binds an exposure to the current operator's account; eager-load
        # the cve + version + module so serialization issues no N+1 queries.
        def account_exposures
          ::System::CveExposure
            .joins(node_module_version: :node_module)
            .where(system_node_modules: { account_id: current_account.id })
            .includes(:cve, node_module_version: :node_module)
        end

        def set_exposure
          @exposure = account_exposures.find(params[:id])
        rescue ActiveRecord::RecordNotFound
          render_not_found("CVE exposure")
        end

        def apply_filters(scope)
          if params[:severity].present?
            scope = scope.where(system_cves: { severity: params[:severity] })
          end

          # `state` is the column name; accept `status` as an alias since
          # other system list endpoints expose a `status` filter.
          state = params[:state].presence || params[:status].presence
          scope = scope.where(state: state) if state.present?

          scope
        end

        def serialize_exposure(exposure)
          cve = exposure.cve
          version = exposure.node_module_version
          mod = version&.node_module

          {
            id: exposure.id,
            state: exposure.state,
            package_name: exposure.package_name,
            package_version: exposure.package_version,
            detected_at: exposure.detected_at,
            resolved_at: exposure.resolved_at,
            resolution_note: exposure.resolution_note,
            metadata: exposure.metadata,
            created_at: exposure.created_at,
            updated_at: exposure.updated_at,
            cve: cve && {
              id: cve.id,
              cve_id: cve.cve_id,
              severity: cve.severity,
              severity_weight: cve.severity_weight,
              summary: cve.summary,
              reference_url: cve.reference_url,
              published_at: cve.published_at,
              feed_source: cve.feed_source
            },
            node_module_version: version && {
              id: version.id,
              version_number: version.version_number,
              promotion_state: version.promotion_state
            },
            node_module: mod && {
              id: mod.id,
              name: mod.name
            }
          }
        end
      end
    end
  end
end
