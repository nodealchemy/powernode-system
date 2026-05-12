# frozen_string_literal: true

module Api
  module V1
    module System
      module WorkerApi
        # Worker-orchestrated embedding pipeline for the package catalog.
        #
        # A single endpoint — `process_embedding_batch` — does one batch's worth
        # of work end-to-end on the server. The flow:
        #
        #   1. Lease a batch via FOR UPDATE SKIP LOCKED, stamp embedding_started_at
        #      so simultaneous lessors don't race.
        #   2. Compose `Package#embedding_text` for each row (single source of
        #      truth — re-embed campaigns produce identical input).
        #   3. Generate embeddings via Ai::Memory::EmbeddingService, which
        #      transparently proxies to the worker over HTTP for the actual
        #      provider call (preserves the server↔worker boundary; the
        #      server thread doesn't block on OpenAI directly).
        #   4. Bulk-write embeddings + stamp embedding_generated_at + clear
        #      embedding_started_at.
        #
        # The worker side (SystemPackageEmbeddingJob) is a thin loop: call this
        # endpoint until `remaining: 0`. Per-repo Redis lock there prevents
        # double-fire when both PackageRepositorySyncService and the backfill
        # rake task enqueue the same repo.
        #
        # If a lease times out (worker died mid-batch, network glitch), the
        # IN_FLIGHT_TTL guard in #stale_in_flight_cutoff puts those rows back
        # in the candidate pool on the next poll.
        class PackagesController < BaseController
          DEFAULT_BATCH_SIZE = 50
          MAX_BATCH_SIZE     = 200
          IN_FLIGHT_TTL      = 10.minutes

          def process_embedding_batch
            authorize_worker_permission!("system.packages.embed")
            return if performed?

            repository = ::System::PackageRepository.find(params.require(:repository_id))
            batch_size = clamp_batch_size(params[:batch_size])
            force      = ActiveModel::Type::Boolean.new.cast(params[:force])

            packages = lease_packages!(repository, batch_size: batch_size, force: force)

            if packages.empty?
              return render_success(
                repository_id: repository.id,
                processed:     0,
                remaining:     0,
                errors:        []
              )
            end

            embed_account = embedding_account_for(repository)
            unless embed_account
              clear_lease!(packages)
              return render_error("no account available for embedding (repository has no account and no fallback)",
                                  status: :unprocessable_entity)
            end

            errors = embed_and_persist!(packages, account: embed_account)

            render_success(
              repository_id: repository.id,
              processed:     packages.size - errors.size,
              remaining:     remaining_count(repository, force: force),
              errors:        errors
            )
          end

          private

          def clamp_batch_size(raw)
            n = raw.to_i
            return DEFAULT_BATCH_SIZE if n <= 0

            [n, MAX_BATCH_SIZE].min
          end

          # Returns the candidate scope for a repo. Excludes rows in-flight
          # within the TTL — stale leases (worker died) fall back in.
          def candidates_for(repository, force:)
            scope = ::System::Package.live.where(package_repository_id: repository.id)
            scope = scope.where(embedding: nil) unless force
            scope.where(
              "embedding_started_at IS NULL OR embedding_started_at < ?",
              Time.current - IN_FLIGHT_TTL
            )
          end

          def lease_packages!(repository, batch_size:, force:)
            leased = nil
            ::System::Package.transaction do
              leased = candidates_for(repository, force: force)
                       .order(::System::Package.lease_order_sql)
                       .limit(batch_size)
                       .lock("FOR UPDATE SKIP LOCKED")
                       .to_a
              if leased.any?
                ::System::Package.where(id: leased.map(&:id))
                                 .update_all(embedding_started_at: Time.current)
              end
            end
            leased
          end

          def clear_lease!(packages)
            ::System::Package.where(id: packages.map(&:id))
                             .update_all(embedding_started_at: nil)
          end

          # Shared repos (account_id IS NULL) need a fallback account for the
          # embedding service's cache + provider lookup. Use the worker's own
          # account when configured; otherwise fall back to the first account
          # (deterministic — first account is usually the platform admin).
          def embedding_account_for(repository)
            return repository.account if repository.account.present?

            current_worker.account if current_worker.respond_to?(:account) && current_worker.account.present?
          rescue StandardError
            nil
          end

          # Generates embeddings and writes them back. Returns an array of
          # per-package error hashes (empty on full success). Failures clear
          # the lease for that specific row so the next poll can retry.
          def embed_and_persist!(packages, account:)
            service = ::Ai::Memory::EmbeddingService.new(account: account)
            texts   = packages.map(&:embedding_text)
            vectors = service.generate_batch(texts)

            errors = []
            packages.each_with_index do |pkg, i|
              vec = vectors[i]
              if vec.is_a?(Array) && vec.size == ::Ai::Memory::EmbeddingService::EMBEDDING_DIMENSION
                pkg.update_columns(
                  embedding:              vec,
                  embedding_generated_at: Time.current,
                  embedding_started_at:   nil
                )
              else
                errors << { package_id: pkg.id, error: "embedding generation returned no vector" }
                pkg.update_columns(embedding_started_at: nil)
              end
            rescue StandardError => e
              Rails.logger.warn("[PackagesEmbedding] persist failed package=#{pkg.id}: #{e.class}: #{e.message}")
              errors << { package_id: pkg.id, error: e.message }
              pkg.update_columns(embedding_started_at: nil)
            end
            errors
          end

          def remaining_count(repository, force:)
            candidates_for(repository, force: force).count
          end
        end
      end
    end
  end
end
