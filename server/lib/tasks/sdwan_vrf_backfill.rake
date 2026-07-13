# frozen_string_literal: true

namespace :sdwan do
  desc "IMP-07014982a6d3: backfill a HostVrfAssignment for every SDWAN peer enrolled before " \
       "IMP-64684f9a0ae6 wired allocation into PeerEnroller. Idempotent — safe to re-run."
  task backfill_host_vrf_assignments: :environment do
    result = ::Sdwan::VrfBackfillService.call

    result.errors.each { |e| Rails.logger.error("[sdwan:backfill_host_vrf_assignments] #{e}") }
    puts "sdwan:backfill_host_vrf_assignments — backfilled #{result.backfilled_count}, #{result.errors.size} error(s)"
  end
end
