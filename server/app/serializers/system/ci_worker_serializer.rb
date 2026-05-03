# frozen_string_literal: true

module System
  # Serializer for ci_worker-role Workers. CRITICAL: never returns the
  # token (or its digest). The plaintext token is returned EXCLUSIVELY
  # by the CiWorkersController's create + rotate_token responses (and
  # only once).
  #
  # Plan: docs/plans/wondrous-yawning-anchor.md (Phase 2 — Chunk 3).
  class CiWorkerSerializer
    def initialize(worker)
      @worker = worker
    end

    def as_json
      {
        id:              @worker.id,
        account_id:      @worker.account_id,
        name:            @worker.name,
        description:     @worker.description,
        status:          @worker.status,
        last_seen_at:    @worker.last_seen_at,
        roles:           @worker.roles.pluck(:name),
        created_at:      @worker.created_at,
        updated_at:      @worker.updated_at
      }
    end
  end
end
