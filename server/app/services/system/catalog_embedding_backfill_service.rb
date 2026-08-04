# frozen_string_literal: true

module System
  # Bounded-batch embedding backfill for the NodeModule + NodeTemplate catalogs,
  # plus the coverage counters the operator rake task prints.
  #
  # WHY NOT THE FULL PACKAGE PIPELINE. System::Package embeds through a worker
  # job (SystemPackageEmbeddingJob) driving a leased worker_api batch endpoint,
  # because that catalog is ~400k rows across many repositories and needs
  # FOR UPDATE SKIP LOCKED arbitration between concurrent workers. The module
  # and template catalogs are three to four orders of magnitude smaller — an
  # account's whole module catalog fits in a handful of batches — so that
  # machinery would be pure ceremony, and a job + endpoint with no caller would
  # be dead code. This service is the seam instead: a worker job wanting to
  # drive it later wraps `call` with a `limit` and loops, with no change to the
  # model or search layers.
  #
  # The server↔worker boundary is still respected: Ai::Memory::EmbeddingService
  # proxies the actual provider call to the worker over HTTP, exactly as the
  # packages controller does — the server thread never talks to OpenAI directly.
  #
  # Freshness: the candidate scope is `embedding_stale` (never embedded, OR
  # edited since the embedding was generated), so re-running the task is a
  # reconcile rather than a one-shot. Nothing enqueues an embed on save today —
  # that is the deliberate follow-up, and until it lands this pass plus the
  # coverage report is how an operator keeps the catalog searchable.
  class CatalogEmbeddingBackfillService
    DEFAULT_BATCH_SIZE = 50
    MAX_BATCH_SIZE     = 200

    KINDS = {
      modules:   ::System::NodeModule,
      templates: ::System::NodeTemplate
    }.freeze

    Result = Struct.new(:processed, :errors, :remaining, keyword_init: true)

    class << self
      # `limit` caps how many rows this call embeds in total (across kinds);
      # nil means "everything stale". `remaining` reports what is left after.
      def call(account:, kinds: KINDS.keys, force: false, batch_size: DEFAULT_BATCH_SIZE, limit: nil)
        raise ArgumentError, "account is required" if account.blank?

        batch_size = clamp_batch_size(batch_size)
        processed  = 0
        errors     = []
        budget     = limit

        Array(kinds).each do |kind|
          model = KINDS.fetch(kind.to_sym) { raise ArgumentError, "unknown catalog kind: #{kind}" }
          next if budget && budget <= 0

          kind_processed, kind_errors = embed_kind(
            model:      model,
            account:    account,
            force:      force,
            batch_size: batch_size,
            budget:     budget
          )
          processed += kind_processed
          errors.concat(kind_errors)
          budget -= (kind_processed + kind_errors.size) if budget
        end

        Result.new(
          processed: processed,
          errors:    errors,
          remaining: remaining_count(account: account, kinds: kinds, force: force)
        )
      end

      # Per-kind counters for the operator coverage report.
      #
      # `embedded` counts rows that hold a vector; `stale` counts rows whose
      # vector predates their last edit. Both matter, and reporting only the
      # first is the trap the platform already learned the hard way — a catalog
      # can read 100% embedded while every vector describes an older row.
      def coverage(account: nil)
        KINDS.transform_values { |model| counts_for(model, account) }
      end

      private

      def clamp_batch_size(raw)
        n = raw.to_i
        return DEFAULT_BATCH_SIZE if n <= 0

        [ n, MAX_BATCH_SIZE ].min
      end

      # `includes(:category)` is load-bearing, not a micro-optimization:
      # NodeModule#embedding_text reads `category&.name`, so composing a batch
      # of 50 without the preload fires 50 extra category queries — the exact
      # shape n-plus-one-check.sh scans for, on the one code path that iterates
      # the whole catalog.
      def candidates(model, account:, force:)
        scope = model.where(account: account)
        scope = scope.includes(:category) if model == ::System::NodeModule
        scope = scope.embedding_stale unless force
        scope
      end

      def embed_kind(model:, account:, force:, batch_size:, budget:)
        processed = 0
        errors    = []
        service   = ::Ai::Memory::EmbeddingService.new(account: account)
        # Rows this call has already handled. Required for termination, not an
        # optimization: under `force` the candidate scope is every row and never
        # shrinks, and a row whose embedding errored stays stale — either would
        # otherwise hand back the same batch forever.
        seen = []

        loop do
          size = budget ? [ batch_size, budget - (processed + errors.size) ].min : batch_size
          break if size <= 0

          scope = candidates(model, account: account, force: force)
          scope = scope.where.not(id: seen) if seen.any?
          batch = scope.order(:created_at).limit(size).to_a
          break if batch.empty?

          seen.concat(batch.map(&:id))
          batch_processed, batch_errors = embed_and_persist(batch, model: model, service: service)
          processed += batch_processed
          errors.concat(batch_errors)
        end

        [ processed, errors ]
      end

      def embed_and_persist(batch, model:, service:)
        # NOTE: a RAISE from generate_batch (or from composing embedding_text)
        # is NOT caught here — the rescue below is scoped to the per-record
        # block body, so it only covers persistence. A provider outage that
        # raises therefore propagates all the way out of `.call`, and a
        # multi-account rake run dies at the first failing account with the
        # earlier accounts' rows already persisted. That is deliberate — a
        # backfill that silently "succeeds" against a dead provider is worse
        # than one that stops — but it means the task is resumable, not
        # transactional: re-run it and `embedding_stale` picks up where it
        # stopped. A provider that RETURNS a bad/nil vector is a different
        # case and is handled per-row as an error below.
        texts   = batch.map(&:embedding_text)
        vectors = service.generate_batch(texts)

        processed = 0
        errors    = []
        batch.each_with_index do |record, i|
          vector = Array(vectors)[i]
          unless vector.is_a?(Array) && vector.size == ::Ai::Memory::EmbeddingService::EMBEDDING_DIMENSION
            errors << { id: record.id, kind: model.name, error: "embedding generation returned no vector" }
            next
          end

          # update_columns: this is bookkeeping, not a domain edit — firing
          # NodeModule's versioning callbacks on an embed would spawn a version
          # row per backfill pass. It also leaves updated_at alone, which is
          # what keeps `embedding_stale` from re-selecting the row forever.
          record.update_columns(embedding: vector, embedding_generated_at: Time.current)
          processed += 1
        rescue StandardError => e
          Rails.logger.warn("[CatalogEmbeddingBackfill] persist failed #{model.name}=#{record.id}: #{e.class}: #{e.message}")
          errors << { id: record.id, kind: model.name, error: e.message }
        end

        [ processed, errors ]
      end

      def remaining_count(account:, kinds:, force:)
        Array(kinds).sum do |kind|
          model = KINDS.fetch(kind.to_sym)
          candidates(model, account: account, force: force).count
        end
      end

      def counts_for(model, account)
        scope    = account ? model.where(account: account) : model.all
        total    = scope.count
        embedded = scope.with_embedding.count
        pending  = scope.embedding_stale.count
        {
          total:    total,
          embedded: embedded,
          stale:    scope.with_embedding.embedding_stale.count,
          pending:  pending,
          percent:  total.positive? ? ((embedded.to_f / total) * 100).round(1) : 0.0
        }
      end
    end
  end
end
