# frozen_string_literal: true

namespace :system do
  desc "DK3: retire DiskImagePublications stuck in failed/verifying (crashed/abandoned CI runs) past a grace window"
  task retire_stuck_disk_image_publications: :environment do
    total_retired = 0
    total_errors = 0

    ::Account.find_each do |account|
      grace_days = (account.settings&.dig("disk_image_stuck_publication_grace_days") ||
                    ::System::DiskImageRetentionService::DEFAULT_GRACE_DAYS).to_i
      result = ::System::DiskImageRetentionService.retire_stuck!(account: account, grace_days: grace_days)

      total_retired += result.retired_count
      total_errors += result.errors.size
      result.errors.each { |e| Rails.logger.error("[system:retire_stuck_disk_image_publications] #{e}") }
    end

    puts "system:retire_stuck_disk_image_publications — retired #{total_retired}, #{total_errors} error(s)"
  end
end
