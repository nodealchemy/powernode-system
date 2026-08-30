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

    # The Vault KV keys the payload at `vault_credential_path` must carry for
    # THIS repository's remote scheme. Single definition, consumed by both
    # RepoSyncService#build_git_env (which enforces it) and the operator
    # serializers (which advertise it) — if the two were separate literals,
    # a credential-path probe built on the advertised set could report "ok"
    # for a payload the sync path rejects, which is the false-reassurance
    # failure this whole surface exists to prevent. IMP-0f914db2c7cf.
    #
    # `username` is required on the HTTPS arm ONLY when the remote carries no
    # userinfo. Git asks GIT_ASKPASS for the username first in that case (and
    # not at all when the URL already names one), so the shim needs a username
    # to answer with. Requiring it unconditionally would advertise a stricter
    # contract than the sync enforces; requiring it never — which is what this
    # method did until review caught it — advertises a LOOSER one, and a looser
    # contract is the false green the probe exists to prevent.
    #
    # Returns `nil`, not `[]`, for a configured path whose scheme matches
    # neither auth branch: build_git_env clones such a remote anonymously and
    # drops the credential path entirely. `[]` means "needs nothing" and is
    # correct only for a repository with no path at all — labelling the one
    # repo whose credentials ARE being ignored as needing none is precisely
    # backwards.
    #
    # Key NAMES only. Nothing in this file ever touches a credential value.
    def required_credential_keys
      return [] if vault_credential_path.blank?

      if repo_url.to_s.start_with?("https://", "http://")
        url_names_a_user? ? %w[password] : %w[password username]
      elsif repo_url.to_s.start_with?("git@", "ssh://")
        %w[ssh_key]
      end
    end

    def schedule_sync!
      ::System::GitopsSyncRun.create!(
        gitops_repository: self,
        started_at: Time.current,
        status: "running"
      )
    end

    private

    # `https://bot@host/repo.git` — a username with no password, which
    # #repo_url_must_not_contain_inline_credentials permits (it rejects only
    # `user:pass@`). Git takes the username from the URL in that shape and
    # prompts only for the password.
    def url_names_a_user?
      repo_url.to_s.match?(%r{://[^/@]+@})
    end

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
