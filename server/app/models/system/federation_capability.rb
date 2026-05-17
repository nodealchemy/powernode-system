# frozen_string_literal: true

module System
  # Per-pair capability policy declaring (per resource kind) which
  # direction data flows + the policy that gates the flow + filter
  # predicates + conflict-resolution strategy.
  #
  # Plan reference: Decentralized Federation §D + P4.1.
  class FederationCapability < BaseRecord
    include System::Base

    DIRECTIONS = %w[push_local_to_remote pull_remote_to_local bidirectional migration_only].freeze
    POLICIES   = %w[manual auto_on_change auto_periodic on_match_filter].freeze
    CONFLICT_RESOLUTIONS = %w[newer_wins_logical_clock local_wins remote_wins prompt].freeze

    self.table_name = "system_federation_capabilities"

    belongs_to :federation_peer, class_name: "System::FederationPeer"

    attribute :filter,       :jsonb, default: -> { {} }
    attribute :sync_cursor,  :jsonb, default: -> { {} }

    validates :resource_kind, presence: true, length: { maximum: 64 },
                              uniqueness: { scope: %i[federation_peer_id direction] }
    validates :direction,           inclusion: { in: DIRECTIONS }
    validates :policy,              inclusion: { in: POLICIES }
    validates :conflict_resolution, inclusion: { in: CONFLICT_RESOLUTIONS }

    scope :by_kind,     ->(kind) { where(resource_kind: kind) }
    scope :auto_flow,   -> { where(policy: %w[auto_on_change auto_periodic on_match_filter]) }
    scope :manual_flow, -> { where(policy: "manual") }
    scope :outbound,    -> { where(direction: %w[push_local_to_remote bidirectional]) }
    scope :inbound,     -> { where(direction: %w[pull_remote_to_local bidirectional]) }

    def auto?
      policy != "manual"
    end

    def covers_direction?(target_direction)
      direction == target_direction.to_s || direction == "bidirectional"
    end

    def filter_matches?(record)
      return true if filter.blank?
      filter.all? do |key, expected|
        actual = record.respond_to?(key) ? record.public_send(key) : record[key]
        case expected
        when Array then Array(actual).intersect?(expected)
        else            actual == expected
        end
      end
    end
  end
end
