# frozen_string_literal: true

# IMP-67aea0728774 — operator entry points for the module/template catalog
# embedding pipeline that backs system_discover_modules / system_discover_templates.
#
#   - backfill_embeddings: embed everything stale (never embedded, or edited
#     since its embedding was generated) in bounded batches. Idempotent; a
#     second run is a no-op. FORCE=true re-embeds the whole catalog — needed
#     after an embedding_text composition change, and after a module rename,
#     since a template's text folds in its modules' text but its own
#     updated_at does not move when a module changes.
#
#   - embedding_coverage: observability. REQUIRED reading before trusting a
#     discovery result — the platform has already learned that a "completed"
#     index can be 0% embedded, so status lies and only the counts don't.
#     `stale` is the second half of that lesson: a catalog can read 100%
#     embedded while every vector describes an older version of the row.
namespace :system do
  namespace :catalog do
    desc "Embed stale NodeModule/NodeTemplate rows. FORCE=true re-embeds everything; ACCOUNT_ID=<uuid> limits to one account; LIMIT=<n> caps rows per account."
    task backfill_embeddings: :environment do
      force = ENV["FORCE"] == "true"
      limit = ENV["LIMIT"].presence&.to_i
      accounts = if ENV["ACCOUNT_ID"].present?
                   Account.where(id: ENV["ACCOUNT_ID"])
      else
                   Account.order(:created_at)
      end

      if accounts.empty?
        puts "No matching accounts — nothing to embed."
        next
      end

      accounts.find_each do |account|
        result = ::System::CatalogEmbeddingBackfillService.call(
          account: account,
          force:   force,
          limit:   limit
        )
        puts "  #{account.name.to_s.ljust(30)} " \
             "embedded=#{result.processed.to_s.rjust(6)} " \
             "errors=#{result.errors.size.to_s.rjust(4)} " \
             "remaining=#{result.remaining.to_s.rjust(6)}"
        result.errors.first(5).each do |err|
          puts "      ! #{err[:kind]} #{err[:id]}: #{err[:error]}"
        end
      end
      puts "Done — force=#{force}."
    end

    desc "Report module/template embedding coverage per account (total / embedded / stale / pending / percent)."
    task embedding_coverage: :environment do
      accounts = if ENV["ACCOUNT_ID"].present?
                   Account.where(id: ENV["ACCOUNT_ID"])
      else
                   Account.order(:created_at)
      end

      if accounts.empty?
        puts "No matching accounts."
        next
      end

      puts [ "account".ljust(30), "kind".ljust(10), "total", "embedded", "stale", "pending", "%" ].join("  ")
      accounts.find_each do |account|
        ::System::CatalogEmbeddingBackfillService.coverage(account: account).each do |kind, counts|
          puts [
            account.name.to_s.ljust(30),
            kind.to_s.ljust(10),
            counts[:total].to_s.rjust(5),
            counts[:embedded].to_s.rjust(8),
            counts[:stale].to_s.rjust(5),
            counts[:pending].to_s.rjust(7),
            "#{counts[:percent]}%".rjust(6)
          ].join("  ")
        end
      end
    end
  end
end
