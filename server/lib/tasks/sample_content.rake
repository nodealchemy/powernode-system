# frozen_string_literal: true

namespace :sample_content do
  desc "Sample/demo content (IMP-f1f96c292991) — dry-run report (id/name/reason) for the 5 business " \
       "example agents, hobby/showcase templates + their exclusive modules, role modules used only by " \
       "smoke seeds, and the local-qemu dev provider. READ-ONLY unless CONFIRM_DELETE=yes is set, in " \
       "which case it destroys every row NOT skipped as still-referenced. ALWAYS run without " \
       "CONFIRM_DELETE first and have the report reviewed — this is destructive and affects far more " \
       "than 5 rows on a typical install."
  task remove: :environment do
    apply = ENV["CONFIRM_DELETE"] == "yes"
    service = System::SampleContentRemovalService.new(dry_run: !apply, confirm: apply)
    report = service.call

    puts "=== Sample content removal — #{report.total_candidates} candidate row(s) ==="
    puts "mode=#{apply ? 'APPLY' : 'DRY RUN'} " \
         "counted=#{report.counted} removed=#{report.total_removed} skipped=#{report.total_skipped}"
    puts

    %i[agents templates modules providers].each do |category|
      removed = report.removed[category]
      skipped = report.skipped[category]
      next if removed.empty? && skipped.empty?

      puts "--- #{category} (removed=#{removed.size} skipped=#{skipped.size}) ---"
      removed.each { |r| puts "  [#{apply ? 'REMOVED' : 'WOULD REMOVE'}] #{r[:class]} #{r[:id]} — #{r[:name]}" }
      skipped.each { |r| puts "  [SKIPPED — #{r[:reason]}] #{r[:class]} #{r[:id]} — #{r[:name]}" }
      puts
    end

    if apply
      puts "CONFIRM_DELETE=yes — #{report.total_removed} row(s) destroyed."
    else
      puts "Dry-run only (set CONFIRM_DELETE=yes to execute). Zero writes performed."
    end
  end
end
