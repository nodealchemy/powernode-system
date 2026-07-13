# frozen_string_literal: true

module System
  # Single source of truth for how a gitea-act-runner builder registers with
  # Gitea: which credential/scope/owner/repo to mint the registration token
  # against, what label + ephemeral flag to hand the runner, and — critically —
  # the runner NAME.
  #
  # Two consumers must agree on every value: the pull-side node_api endpoint
  # (Api::V1::System::NodeApi::ConfigController#ci_runner_registration, which
  # tells act_runner what to register as) and the lease service
  # (System::CiRunnerLeaseService, which correlates the resulting GitRunner row
  # back to a lease). Centralizing them here keeps them in lockstep.
  #
  # Every value is operator-overridable via SiteSetting; the fallbacks match the
  # posture the endpoint shipped with in inc2 (org scope, no per-repo mint).
  class CiRunnerRegistrationResolver
    # Fallback owner for the org-scope registration token (SiteSetting
    # "ci_runner_owner" overrides).
    OWNER_DEFAULT = "powernode"

    # Fallback runner label (SiteSetting "ci_runner_label" overrides).
    # `fleet-amd64` is what Actions workflows target via `runs-on:`; the trailing
    # `:docker://...` is the default job image act_runner falls back to when a
    # workflow step doesn't pin its own `container:`.
    LABEL_DEFAULT = "fleet-amd64:docker://ghcr.io/catthehacker/ubuntu:act-24.04"

    def initialize(account:)
      @account = account
    end

    # Gitea credential to mint the registration token against. SiteSetting
    # "ci_runner_git_credential_id" is an explicit operator override; absent
    # that, the account's single active Gitea credential. More than one active
    # Gitea credential with no override is AMBIGUOUS → nil (don't guess).
    def credential
      configured_id = ::SiteSetting.get("ci_runner_git_credential_id").presence
      return @account.git_provider_credentials.active.find_by(id: configured_id) if configured_id

      candidates = @account.git_provider_credentials.active
                           .joins(:provider)
                           .where(git_providers: { provider_type: "gitea" }).to_a
      candidates.one? ? candidates.first : nil
    end

    # :repo | :org | :admin — defaults to :org (a single org-scope token covers
    # every repo under #owner without a per-repo mint).
    def scope
      (::SiteSetting.get("ci_runner_scope").presence || "org").to_sym
    end

    def owner
      ::SiteSetting.get("ci_runner_owner").presence || OWNER_DEFAULT
    end

    # Only required for :repo scope; nil is fine for :org/:admin.
    def repo
      ::SiteSetting.get("ci_runner_repo").presence
    end

    def label
      ::SiteSetting.get("ci_runner_label").presence || LABEL_DEFAULT
    end

    def ephemeral?
      ::SiteSetting.get("ci_runner_ephemeral").to_s == "true"
    end

    # Deterministic-from-id AND collision-free runner name.
    #
    # Uses the random rand_b tail of the UUIDv7 (last 12 hex chars) — NOT
    # id.first(8). The platform's uuidv7() overlays the 48-bit millisecond
    # timestamp big-endian into the first 6 bytes, so the first 8 hex chars are
    # the top 32 bits of the ms clock and are IDENTICAL for any two ids minted
    # in the same ~65.5s window (top 32 of 48 bits roll every 2**16 ms). A
    # recycle+backfill pool routinely mints two members inside that window, so
    # fleet-#{id.first(8)} collides — breaking the unique correlation the lease
    # relies on. The tail is fully random and unique per instance.
    def self.runner_name(instance)
      "fleet-#{instance.id.to_s.delete('-').last(12)}"
    end
  end
end
