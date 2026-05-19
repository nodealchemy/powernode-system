# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Wraps the `system_list_package_repositories` MCP action as a skill so
      # natural-language queries like "how many package repositories do I have
      # configured?", "what package repos exist?", or "list my apt sources"
      # become discoverable via the skill graph + dispatchable by the router.
      #
      # The bare MCP action exists already, but skills are what `discover_skills`
      # ranks. Without a wrapper, the router can't surface this capability for
      # chat queries. Mirrors the pattern for system-suggest-architectures-for-fleet
      # (thin executor over an existing MCP action so semantic discovery works).
      class ListPackageRepositoriesSummaryExecutor < BaseSkillExecutor
        skill_descriptor(
          name: "list_package_repositories_summary",
          description: "Summarize the package repositories configured for the operator's account — counts, kinds (apt/rpm/dnf), visibility (shared vs account), sync status. Use for 'how many package repos', 'what package sources', 'list my repositories', or similar inventory queries.",
          category: "devops",
          inputs: {
            intent: { type: "string", required: true,
                      description: "Free-text query — typically the user's natural-language ask about repositories" }
          },
          outputs: {
            total:           :integer,
            by_kind:         :object,   # { apt: N, rpm: N, dnf: N }
            by_visibility:   :object,   # { shared: N, account: N }
            by_sync_status:  :object,   # { idle: N, syncing: N, failed: N }
            repositories:    :array,    # full list with name, kind, package_count, sync_status
            summary:         :string    # one-line operator-friendly summary
          }
        )

        binds_to "System Concierge"

        protected

        # `intent` is accepted for AUTO_INVOKABLE_INPUT_KEYS routing compatibility
        # but not actually consumed — this skill always returns the full
        # repository list regardless of query phrasing. The intent text is
        # captured in the audit trail so we can refine search semantics later.
        def perform(intent: nil)
          return failure("account is required") unless @account.present?

          repos = ::System::PackageRepository.accessible_to(@account).order(:name).to_a

          by_kind = repos.group_by(&:kind).transform_values(&:size)
          by_visibility = {
            "shared"  => repos.count(&:shared?),
            "account" => repos.count { |r| !r.shared? }
          }
          by_sync_status = repos.group_by(&:sync_status).transform_values(&:size)

          rows = repos.map do |r|
            {
              id:            r.id,
              name:          r.name,
              kind:          r.kind,
              visibility:    r.visibility,
              base_url:      r.base_url,
              package_count: r.package_count,
              sync_status:   r.sync_status,
              last_synced_at: r.last_synced_at&.iso8601,
              shared:        r.shared?
            }
          end

          summary_line = build_summary_line(repos.size, by_kind, by_visibility, by_sync_status)

          success(
            intent:          intent,
            total:           repos.size,
            by_kind:         by_kind,
            by_visibility:   by_visibility,
            by_sync_status:  by_sync_status,
            repositories:    rows,
            summary:         summary_line
          )
        end

        private

        def build_summary_line(total, by_kind, by_visibility, by_sync_status)
          return "No package repositories configured." if total.zero?

          kind_parts = by_kind.map { |k, n| "#{n} #{k}" }.join(" + ")
          shared_n = by_visibility["shared"]
          account_n = by_visibility["account"]
          vis_part = "#{shared_n} shared / #{account_n} account-scoped"
          status_summary = by_sync_status.any? { |s, _| s == "failed" } ? " (some failing)" : ""

          "#{total} package repositories configured (#{kind_parts}; #{vis_part})#{status_summary}."
        end
      end
    end
  end
end
