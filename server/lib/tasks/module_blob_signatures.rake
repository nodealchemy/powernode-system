# frozen_string_literal: true

namespace :system do
  namespace :modules do
    desc "Sign the erofs blob of every CURRENT module version that has no platform blob signature " \
         "(System::ModuleBlobSigner.backfill!). DRY RUN unless APPLY=1. Optional ACCOUNT_ID=<uuid>. " \
         "Idempotent — a signed version is no longer a candidate. See docs/runbooks/module-signature-verification.md."
    task sign_blobs: :environment do
      account = ENV["ACCOUNT_ID"].present? ? ::Account.find(ENV["ACCOUNT_ID"]) : nil
      apply   = ENV["APPLY"] == "1"

      preview = ::System::ModuleBlobSigner.backfill!(account: account, dry_run: true)
      names = preview[:candidates].map { |v| "#{v.node_module.name}@#{v.version_number}" }
      puts "system:modules:sign_blobs — #{names.size} current version(s) lack a platform blob signature."
      # Bulk-op safety: state the count, show the first 3 and the last 1.
      shown = names.size > 4 ? names.first(3) + [ "…", names.last ] : names
      shown.each { |n| puts "  #{n}" }

      unless apply
        puts "DRY RUN — nothing signed. Re-run with APPLY=1 to sign these #{names.size} version(s)."
        next
      end

      report = ::System::ModuleBlobSigner.backfill!(account: account, dry_run: false)
      report[:errors].each { |e| Rails.logger.error("[system:modules:sign_blobs] #{e}"); puts "  FAILED #{e}" }
      puts "system:modules:sign_blobs — signed #{report[:signed]}, failed #{report[:failed]}."
    end
  end
end
