# frozen_string_literal: true

namespace :sdwan do
  desc "SDWAN overlay debris — dry-run report (id/name/classification) for test/smoke networks, " \
       "dead (terminated-instance) peers, and revoked federation rows. READ-ONLY unless " \
       "CONFIRM_DELETE=yes is set, in which case it destroys every row classified safe_to_delete. " \
       "ALWAYS run without CONFIRM_DELETE first and have the row-by-row classification reviewed."
  task debris_report: :environment do
    rows = ::Sdwan::DebrisReport.call
    safe = rows.select(&:safe_to_delete)
    keep = rows.reject(&:safe_to_delete)

    puts "=== SDWAN debris report — #{rows.size} candidate row(s) ==="
    puts "safe_to_delete=#{safe.size} keep=#{keep.size}"
    puts

    rows.group_by(&:kind).each do |kind, kind_rows|
      puts "--- #{kind} (#{kind_rows.size}) ---"
      kind_rows.each do |row|
        tag = row.safe_to_delete ? "SAFE_TO_DELETE" : "KEEP"
        puts "  [#{tag}] #{row.id} — #{row.label} — #{row.reason}"
      end
      puts
    end

    puts "--- reviewable deletion script (NOT executed unless CONFIRM_DELETE=yes) ---"
    safe.each { |row| puts row.destroy_code }
    puts

    if ENV["CONFIRM_DELETE"] == "yes"
      puts "CONFIRM_DELETE=yes — executing #{safe.size} destroy(s)..."
      safe.each do |row|
        row.kind.constantize.find(row.id).destroy!
        Rails.logger.info("[sdwan:debris_report] destroyed #{row.kind}##{row.id}")
      end
      puts "Done."
    else
      puts "Dry-run only (set CONFIRM_DELETE=yes to execute). Zero writes performed."
    end
  end
end
