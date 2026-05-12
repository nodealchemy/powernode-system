# frozen_string_literal: true

# T2.C — vendor-tag aliases on NodeArchitecture.
#
# Operators occasionally need to register vendor-specific architecture
# tags (`amd64-graviton`, `aarch64-pacbti`, `x86_64-v3`, etc.) without
# polluting the canonical name. The aliases column stores the alternate
# names a row should answer to in NodeArchitecture.find_normalized
# lookups.
#
# Storage: JSONB array of lowercase strings. Lowercase-normalization
# happens in the model's before_validation hook so the GIN ?| / @>
# operators don't need LOWER() wrappers (which would skip the index).
class AddAliasesToNodeArchitectures < ActiveRecord::Migration[8.0]
  def change
    add_column :system_node_architectures, :aliases, :jsonb, default: [], null: false
    # GIN index supports both @> containment and ?| any-of lookups —
    # the exact form find_normalized uses.
    add_index :system_node_architectures, :aliases, using: :gin, name: "idx_node_architectures_aliases_gin"
  end
end
