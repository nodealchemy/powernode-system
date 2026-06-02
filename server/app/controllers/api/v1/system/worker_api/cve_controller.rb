# frozen_string_literal: true

module Api
  module V1
    module System
      module WorkerApi
        # Worker entry point for CVE feed ingestion. Hit hourly by
        # SystemCveFeedJob; runs FeedIngestService (mode-selectable adapter)
        # then triggers ExposureCalculator for each affected CVE.
        #
        # Reference: Golden Eclipse plan M-D2-2.
        class CveController < BaseController
          def ingest
            authorize_worker_permission!("system.fleet.reconcile")
            return if performed?

            ingest_result = ::System::CveOps::FeedIngestService.ingest!(
              source: params[:source].presence || "nvd",
              since: parse_since,
              fixture_path: params[:fixture_path].presence
            )

            # FeedIngestService::Result = Struct.new(:ok?, ...) — accessor is `ok?`, not `success?`.
            unless ingest_result.ok?
              return render_error("CVE ingest failed: #{ingest_result.error}", 422)
            end

            exposures_updated = ::System::CveOps::ExposureRecomputeService.recompute_recent!
            render_success(
              ingested_count: ingest_result.ingested_count,
              updated_count: ingest_result.updated_count,
              exposures_updated: exposures_updated
            )
          end

          private

          def parse_since
            return nil if params[:since].blank?
            Time.iso8601(params[:since])
          rescue ArgumentError
            nil
          end
        end
      end
    end
  end
end
