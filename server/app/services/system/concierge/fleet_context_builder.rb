# frozen_string_literal: true

module System
  module Concierge
    # Builds a runtime fleet + SDWAN context snippet that the System Concierge
    # uses as a "current snapshot" system message at conversation start.
    #
    # Output is a plain-text Markdown summary the LLM reads as preamble
    # context. Per-tenant (account-scoped) — never leaks cross-account state.
    #
    # Truncated to MAX_CHARS to keep the conversation's first system message
    # bounded; deeper queries are answered by dispatching tool calls.
    #
    # Reference: comprehensive stabilization sweep Phase 10.3.
    class FleetContextBuilder
      MAX_CHARS = 4_000
      RECENT_EVENT_LIMIT = 10
      RECENT_CVE_LIMIT = 5

      def self.build(account:)
        new(account: account).build
      end

      def initialize(account:)
        @account = account
      end

      def build
        return "" unless @account

        sections = [
          fleet_summary_section,
          sdwan_summary_section,
          recent_events_section,
          cve_exposure_section
        ].compact_blank

        truncate(sections.join("\n\n"))
      rescue StandardError => e
        Rails.logger.warn("[Concierge::FleetContextBuilder] failed: #{e.class}: #{e.message}")
        ""
      end

      private

      def fleet_summary_section
        node_count = ::System::Node.where(account_id: @account.id).count
        instance_scope = ::System::NodeInstance.joins(:node)
                                               .where(system_nodes: { account_id: @account.id })
        instance_total = instance_scope.count
        instance_status_counts = instance_scope.group(:status).count

        module_count = ::System::NodeModule.where(account_id: @account.id).count
        template_count = ::System::NodeTemplate.where(account_id: @account.id).count

        lines = [
          "## Fleet snapshot",
          "- Nodes: #{node_count}",
          "- Templates: #{template_count}",
          "- Modules: #{module_count}",
          "- Node instances: #{instance_total}#{format_status_breakdown(instance_status_counts)}"
        ]
        lines.join("\n")
      end

      def sdwan_summary_section
        return nil unless defined?(::Sdwan::Network)

        network_count = ::Sdwan::Network.where(account_id: @account.id).count
        return nil if network_count.zero?

        peer_total = ::Sdwan::Peer.where(account_id: @account.id).count
        access_grant_count = ::Sdwan::AccessGrant.where(account_id: @account.id).count if defined?(::Sdwan::AccessGrant)
        vip_count = ::Sdwan::VirtualIp.where(account_id: @account.id).count if defined?(::Sdwan::VirtualIp)

        lines = [
          "## SDWAN snapshot",
          "- Networks: #{network_count}",
          "- Peers: #{peer_total}"
        ]
        lines << "- Active access grants: #{access_grant_count}" if access_grant_count
        lines << "- Virtual IPs: #{vip_count}" if vip_count
        lines.join("\n")
      rescue StandardError
        nil
      end

      def recent_events_section
        return nil unless defined?(::System::FleetEvent)

        events = ::System::FleetEvent.where(account_id: @account.id)
                                     .order(created_at: :desc)
                                     .limit(RECENT_EVENT_LIMIT)
        return nil if events.empty?

        lines = [ "## Recent fleet events (last #{events.size})" ]
        events.each do |event|
          timestamp = event.created_at&.iso8601 || "unknown"
          lines << "- [#{event.severity}] #{event.kind} (#{timestamp})"
        end
        lines.join("\n")
      rescue StandardError
        nil
      end

      def cve_exposure_section
        return nil unless defined?(::System::CveExposure)

        open_count = ::System::CveExposure.joins(node_module_version: { node_module: :account })
                                          .where(accounts: { id: @account.id }, state: "open")
                                          .count
        return nil if open_count.zero?

        recent = ::System::CveExposure.joins(node_module_version: { node_module: :account })
                                      .where(accounts: { id: @account.id }, state: "open")
                                      .order(detected_at: :desc)
                                      .limit(RECENT_CVE_LIMIT)
                                      .pluck(:package_name)

        lines = [ "## CVE exposures" ]
        lines << "- Open: #{open_count}"
        lines << "- Recent affected packages: #{recent.uniq.first(5).join(', ')}" if recent.any?
        lines.join("\n")
      rescue StandardError
        nil
      end

      def format_status_breakdown(counts)
        return "" if counts.empty?

        breakdown = counts.sort_by { |status, _| status.to_s }
                          .map { |status, count| "#{status}=#{count}" }
                          .join(", ")
        " (#{breakdown})"
      end

      def truncate(text)
        return text if text.length <= MAX_CHARS

        suffix = "\n\n_(context truncated to #{MAX_CHARS} chars)_"
        keep = [ MAX_CHARS - suffix.length, 0 ].max
        text[0, keep] + suffix
      end
    end
  end
end
