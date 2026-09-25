# frozen_string_literal: true

# Seeded text for this extension's GLOBAL canonical agents that must reach
# installs which already have the rows — the extension's half of core's
# db/seeds/content/canonical_agent_content.rb. Seeds run only on an install's
# first boot, so a data migration applies this file through core's
# Ai::Agents::CanonicalContentRefresh, and the seeds read the same values.
#
# `previous` lists what earlier seeds wrote. A row with no stamp yet is updated
# only when its text is one of these (or blank); any other text is an operator
# edit and is kept. When changing a value here, move the old value into
# `previous` and add a migration that re-applies this file.
module System
  module Seeds
    module CanonicalAgentContent
      AGENTS = {
        "cve-responder" => {
          description: "CVE intake and remediation: SBOM ingest, exposure scans and patch orchestration. " \
                       "Use when a CVE must be triaged, its exposure measured, or a patch planned and rolled out.",
          previous: {
            description: [ "CVE intake + remediation — SBOM ingest, exposure scan, patch orchestration" ]
          }
        },
        "fleet-autonomy" => {
          description: "Self-improving fleet reconciler that runs sensors, gates actions and extracts learnings. " \
                       "Use when fleet drift, a boot-image rollout or an application deploy across nodes must " \
                       "be reconciled.",
          previous: {
            description: [ "Self-improving fleet reconciler — runs sensors, gates actions, extracts learnings" ]
          }
        },
        "infrastructure-generalist" => {
          description: "Operator chat agent for the full system extension surface (fleet, SDWAN, container " \
                       "runtimes, modules, disk image CI); read-only by default, it dispatches state-changing " \
                       "skills with operator confirmation. Use when an infrastructure question spans several " \
                       "system areas or no narrower manager fits.",
          previous: {
            description: [
              "Operator chat agent for the full system extension surface (fleet, SDWAN, container runtimes, " \
              "modules, disk image CI) — read-only by default, dispatches state-changing skills with operator " \
              "confirmation",
              "Operator chat agent for fleet + SDWAN — read-only by default, dispatches state-changing skills " \
              "with operator confirmation"
            ]
          }
        },
        "runtime-manager" => {
          description: "Container runtime lifecycle reconciler for Docker hosts and K3s clusters; gates provision, " \
                       "decommission and upgrade actions. Use when a Docker host or K3s cluster must be " \
                       "provisioned, upgraded or decommissioned.",
          previous: {
            description: [ "Container runtime lifecycle reconciler — Phase 1 Docker + Phase 2 K3s clusters; " \
                           "gates provision/decommission/upgrade actions" ]
          }
        },
        "sdwan-manager" => {
          description: "SDWAN reconciler for peer health, topology compilation, VIP failover, federation and BGP. " \
                       "Use when SDWAN peers, routes, VIPs or federation need configuring or repair.",
          previous: {
            description: [ "SDWAN reconciler — peer health, topology compilation, VIP failover, federation, BGP" ]
          }
        }
      }.freeze

      module_function

      def description(slug)
        AGENTS.fetch(slug).fetch(:description)
      end

      def fields(slug)
        AGENTS.fetch(slug).except(:previous)
      end

      def previous(slug)
        AGENTS.fetch(slug).fetch(:previous, {})
      end

      # Seed path: the catalog fields for the agent's slug over `inline` (fields
      # the seed still owns, e.g. its system prompt), through the edit guard.
      def refresh!(agent, inline = {})
        apply!(agent, inline.merge(fields(agent.slug)), previous(agent.slug))
      end

      # Migration path: every catalog entry against its global row in `model`.
      def refresh_catalog!(model)
        AGENTS.each_key.filter_map do |slug|
          agent = model.find_by(account_id: nil, slug: slug)
          apply!(agent, fields(slug), previous(slug)) if agent
        end
      end

      def revert_catalog!(model)
        AGENTS.each_key do |slug|
          agent = model.find_by(account_id: nil, slug: slug)
          ::Ai::Agents::CanonicalContentRefresh.revert!(agent, fields(slug)) if agent
        end
      end

      def apply!(agent, fields, previous)
        outcome = ::Ai::Agents::CanonicalContentRefresh.apply!(agent, fields, previous: previous)
        if outcome.skipped?
          message = "[CanonicalContent] #{outcome.slug}: kept operator-edited #{outcome.skipped.join(', ')}"
          Rails.logger.warn(message)
          puts "  ⚠️  #{message}"
        end
        outcome
      end
    end
  end
end
