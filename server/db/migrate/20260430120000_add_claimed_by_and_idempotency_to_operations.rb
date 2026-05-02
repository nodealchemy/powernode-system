# frozen_string_literal: true

# P0-3 + P1-10 hardening: idempotent operation creation + worker-claim tracking.
#
# - `idempotency_key`: caller-supplied opaque token (uuid, ulid, etc.) that
#   makes POST /system/operations idempotent across retries. Unique by
#   account where present (partial index — null is allowed for legacy ops).
# - `claimed_by_worker_id`: which Worker took this operation through the AASM
#   start event. Populated from worker_api/execute → ExecutionDispatcher.
class AddClaimedByAndIdempotencyToOperations < ActiveRecord::Migration[8.1]
  def change
    add_reference :system_operations, :claimed_by_worker,
      type: :uuid,
      foreign_key: { to_table: :workers, on_delete: :nullify },
      null: true,
      index: true

    add_column :system_operations, :idempotency_key, :string

    # Partial unique index: idempotency only enforced where a key is supplied.
    # Existing operations without keys remain unconstrained.
    add_index :system_operations,
      [:account_id, :idempotency_key],
      unique: true,
      where: "idempotency_key IS NOT NULL",
      name: "idx_system_operations_idempotency"
  end
end
