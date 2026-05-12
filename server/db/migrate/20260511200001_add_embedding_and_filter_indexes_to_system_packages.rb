# frozen_string_literal: true

# Adds the embedding column + lifecycle markers used by SystemPackageEmbeddingJob,
# plus btree indexes on the two filter dimensions that didn't already have one.
#
# Existing schema:
#   - pg_trgm GIN on `name` and `description` (lexical/fuzzy search) — kept
#   - JSONB GIN on `provides` and `depends` (capability/dependency lookups) — kept
#
# New:
#   - `embedding vector(1536)` — pgvector column populated by the worker
#     via SystemPackageEmbeddingJob (text-embedding-3-small / 1536-dim).
#   - `embedding_started_at` — in-flight marker set by the server when a row
#     is leased to a worker; prevents two workers from racing on the same row.
#   - `embedding_generated_at` — freshness marker set when the worker writes
#     the vector back; lets the lessor re-embed rows whose metadata has changed.
#   - HNSW index on the embedding (cosine ops) — semantic search backbone.
#   - btree on `license` and `section_or_group` — operator/AI filter dimensions.
class AddEmbeddingAndFilterIndexesToSystemPackages < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def up
    enable_extension "vector" unless extension_enabled?("vector")

    # Column add is instant on PG >= 11 for nullable columns (catalog-only,
    # no table rewrite) so it's safe inside disable_ddl_transaction!.
    add_column :system_packages, :embedding,              :vector,   limit: 1536 unless column_exists?(:system_packages, :embedding)
    add_column :system_packages, :embedding_started_at,   :datetime              unless column_exists?(:system_packages, :embedding_started_at)
    add_column :system_packages, :embedding_generated_at, :datetime              unless column_exists?(:system_packages, :embedding_generated_at)

    add_index :system_packages, :embedding,
      using:      :hnsw,
      opclass:    :vector_cosine_ops,
      algorithm:  :concurrently,
      name:       "idx_packages_embedding_hnsw",
      if_not_exists: true

    add_index :system_packages, :license,
      algorithm:     :concurrently,
      name:          "idx_packages_license",
      if_not_exists: true

    add_index :system_packages, :section_or_group,
      algorithm:     :concurrently,
      name:          "idx_packages_section",
      if_not_exists: true
  end

  def down
    remove_index :system_packages, name: "idx_packages_section",         algorithm: :concurrently, if_exists: true
    remove_index :system_packages, name: "idx_packages_license",         algorithm: :concurrently, if_exists: true
    remove_index :system_packages, name: "idx_packages_embedding_hnsw",  algorithm: :concurrently, if_exists: true

    remove_column :system_packages, :embedding_generated_at, if_exists: true
    remove_column :system_packages, :embedding_started_at,   if_exists: true
    remove_column :system_packages, :embedding,              if_exists: true
  end
end
