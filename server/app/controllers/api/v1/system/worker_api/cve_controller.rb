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

            unless ingest_result.ok?
              return render_error("CVE ingest failed: #{ingest_result.error}", 422)
            end

            exposures_updated = recompute_exposures_for_recent_cves
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

          # For each CVE ingested or updated in the last 30 minutes, recompute
          # exposures across every account that has a NodeModule. The window
          # must be at least the worker tick interval (60s) plus generous
          # slack for clock skew between worker and server.
          def recompute_exposures_for_recent_cves
            cutoff = 30.minutes.ago
            recent = ::System::Cve.where("ingested_at >= ?", cutoff)
            total_updated = 0

            Account.find_each do |account|
              recent.find_each do |cve|
                result = ::System::CveOps::ExposureCalculator.calculate!(cve: cve, account: account)
                total_updated += result.exposures_created + result.exposures_updated if result.ok?
              end
            end

            total_updated
          end
        end
      end
    end
  end
end
