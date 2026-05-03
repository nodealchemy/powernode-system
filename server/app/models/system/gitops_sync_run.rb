# frozen_string_literal: true

module System
  # One row per GitOps reconcile attempt. Captures: starting/ending time,
  # diff count, list of proposals opened, status, error message.
  # Used for operator audit and the GitopsPage timeline.
  class GitopsSyncRun < BaseRecord
    include System::Base

    STATUSES = %w[running success failed partial].freeze

    belongs_to :gitops_repository,
               class_name: "System::GitopsRepository",
               foreign_key: :gitops_repository_id

    delegate :account, to: :gitops_repository

    validates :status, inclusion: { in: STATUSES }
    validates :started_at, presence: true

    scope :recent, -> { order(started_at: :desc) }
    scope :failed, -> { where(status: %w[failed partial]) }
    scope :for_account, ->(account) {
      joins(:gitops_repository).where(system_gitops_repositories: { account_id: account.id })
    }

    def duration_seconds
      return nil if completed_at.blank?
      completed_at - started_at
    end

    def proposals
      return ::Ai::AgentProposal.none if proposal_ids.blank?
      ::Ai::AgentProposal.where(id: proposal_ids)
    end

    def finalize!(status:, diff_count: 0, proposal_ids: [], synced_revision: nil, diff_summary: {}, error_message: nil)
      update!(
        completed_at: Time.current,
        status: status,
        diff_count: diff_count,
        proposal_ids: proposal_ids,
        synced_revision: synced_revision,
        diff_summary: diff_summary,
        error_message: error_message
      )
    end
  end
end
