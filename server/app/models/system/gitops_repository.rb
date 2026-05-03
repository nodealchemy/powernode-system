# frozen_string_literal: true

module System
  # A registered git repository whose contents describe desired fleet state.
  # The reconciler clones/pulls this repo on a 5-minute cron, parses
  # `fleet.yaml` (or whatever path_prefix points to), diffs against live
  # state, and opens `Ai::AgentProposal` rows for each diff.
  #
  # Storage convention: `repo_url` accepts HTTPS or SSH URLs; deploy-key
  # authentication is via `vault_credential_path` pointing at a Vault KV
  # secret with `{ ssh_key: "...", username: "...", password: "..." }`.
  # URLs with embedded credentials (https://user:pass@...) are rejected at
  # validation to prevent inline-credential leakage.
  #
  # Reference: comprehensive stabilization sweep P5; Golden Eclipse M-D2-3.
  class GitopsRepository < BaseRecord
    include System::Base

    STATUSES = %w[pending success failed partial].freeze

    belongs_to :account
    has_many :sync_runs,
             class_name: "System::GitopsSyncRun",
             foreign_key: :gitops_repository_id,
             dependent: :destroy

    validates :name, presence: true,
                     length: { maximum: 64 },
                     uniqueness: { scope: :account_id }
    validates :repo_url, presence: true, length: { maximum: 512 }
    validates :branch, presence: true, length: { maximum: 128 }
    validates :last_status, inclusion: { in: STATUSES }

    validate :repo_url_must_not_contain_inline_credentials
    validate :path_prefix_must_be_relative

    scope :enabled, -> { where(enabled: true) }
    scope :due_for_sync, ->(staleness: 5.minutes) {
      enabled.where("last_synced_at IS NULL OR last_synced_at < ?", staleness.ago)
    }

    def last_run
      sync_runs.order(started_at: :desc).first
    end

    def schedule_sync!
      ::System::GitopsSyncRun.create!(
        gitops_repository: self,
        started_at: Time.current,
        status: "running"
      )
    end

    private

    def repo_url_must_not_contain_inline_credentials
      return if repo_url.blank?

      if repo_url.match?(%r{://[^/@]+:[^@]+@})
        errors.add(:repo_url, "must not contain inline credentials; use vault_credential_path instead")
      end
    end

    def path_prefix_must_be_relative
      return if path_prefix.blank?

      if path_prefix.start_with?("/") || path_prefix.include?("..")
        errors.add(:path_prefix, "must be a relative path without parent traversal")
      end
    end
  end
end
