# frozen_string_literal: true

# Package-repo sync throughput (change-detection + fingerprint fast-path):
#   * sync_fingerprint — a stable digest of the upstream index metadata
#     (apt InRelease's per-Packages SHA256 set; rpm repomd data checksums).
#     When unchanged since the last successful sync, the whole sync is
#     skipped (no fetch/parse/diff) — the common "daily tick, nothing
#     changed" case becomes two small HTTP GETs.
#   * parser_version — the PackageRepositorySyncService::PARSER_VERSION in
#     effect at the last successful sync. When the code's parser version is
#     newer, one full reparse is forced so stored metadata refreshes after a
#     parser change (change-detection otherwise skips unchanged rows forever).
class AddSyncFingerprintToPackageRepositories < ActiveRecord::Migration[8.0]
  def change
    add_column :system_package_repositories, :sync_fingerprint, :text
    add_column :system_package_repositories, :parser_version, :integer, null: false, default: 0
  end
end
