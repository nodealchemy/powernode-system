# frozen_string_literal: true

module System
  module CveOps
    # Recomputes CVE exposures for recently-ingested CVEs. Extracted from
    # WorkerApi::CveController (controllers stay thin) and optimized:
    #
    #   - materialize the recent-CVE set ONCE (the prior controller code
    #     re-ran the query inside the account loop, once per account)
    #   - only iterate accounts that actually have a NodeModule — a CVE cannot
    #     expose an account with no modules, so the old O(all_accounts × cves)
    #     sweep wasted a calculate! call per empty account
    #   - early-exit when there are no recent CVEs or no module-bearing accounts
    #
    # Reference: Golden Eclipse plan M-D2-2; operational-completeness audit P-cve.
    class ExposureRecomputeService
      # The window must be >= the worker tick interval (60s) plus generous
      # slack for clock skew between worker and server.
      DEFAULT_WINDOW = 30.minutes

      def self.recompute_recent!(window: DEFAULT_WINDOW)
        new(window: window).recompute_recent!
      end

      def initialize(window: DEFAULT_WINDOW)
        @window = window
      end

      def recompute_recent!
        recent_cves = ::System::Cve.where("ingested_at >= ?", @window.ago).to_a
        return 0 if recent_cves.empty?

        account_ids = ::System::NodeModule.distinct.pluck(:account_id)
        return 0 if account_ids.empty?

        total_updated = 0
        ::Account.where(id: account_ids).find_each do |account|
          recent_cves.each do |cve|
            result = ::System::CveOps::ExposureCalculator.calculate!(cve: cve, account: account)
            # ExposureCalculator::Result = Struct.new(:ok?, ...) — accessor is `ok?`.
            total_updated += result.exposures_created.to_i + result.exposures_updated.to_i if result.ok?
          end
        end

        total_updated
      end
    end
  end
end
