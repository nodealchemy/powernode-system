# frozen_string_literal: true

namespace :sdwan do
  desc "IMP-43cf1e6b5541: backfill a Sdwan::VirtualIpAssignment history row for every stray " \
       "(phantom) holder already sitting in a non-anycast VIP's holder_peer_ids from before " \
       "this task's on-change validation existed. Idempotent — safe to re-run."
  task backfill_phantom_vip_holders: :environment do
    result = ::Sdwan::VirtualIpPhantomHolderBackfillService.call

    result.errors.each { |e| Rails.logger.error("[sdwan:backfill_phantom_vip_holders] #{e}") }
    puts "sdwan:backfill_phantom_vip_holders — backfilled #{result.backfilled_count}, #{result.errors.size} error(s)"
  end
end
