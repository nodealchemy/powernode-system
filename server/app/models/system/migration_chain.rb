# frozen_string_literal: true

module System
  # P9.5 — Multi-hop migration chain envelope.
  #
  # A chain represents a sequence of N hops (A → B → C → ...) that
  # threads a single resource (or resource graph) through multiple
  # peers. Each hop is a normal `System::Migration` row linked to
  # this chain via `migration_chain_id` + `chain_position`.
  #
  # Lifecycle:
  #
  #   planned ──advance──→ in_flight ──finish──→ completed (terminal)
  #         │                  │
  #         │                  └─fail──→ failed (terminal, stuck-at-hop-K)
  #         └──cancel──→ cancelled (terminal)
  #
  # The chain "stops" wherever the most-recent hop's status lands. If
  # hop K succeeds and hop K+1 fails, the UUID lives on hop K's
  # destination; the chain is `failed` with `current_hop_index = K+1`
  # and the operator decides whether to retry that hop, abandon the
  # chain (treating hop K's destination as final), or trigger a
  # corrective rollback chain.
  #
  # Per Locked Decision #14, at no point does the UUID exist on
  # multiple peers — each hop runs as a P5 migrate, source deletes
  # after dest acks.
  class MigrationChain < BaseRecord
    include System::Base

    STATUSES = %w[planned in_flight completed failed cancelled].freeze
    TERMINAL_STATUSES = %w[completed failed cancelled].freeze
    OPERATIONS = %w[migrate duplicate].freeze

    TRANSITIONS = {
      "planned"    => %w[in_flight cancelled],
      "in_flight"  => %w[completed failed],
      "completed"  => [],
      "failed"     => [],
      "cancelled"  => []
    }.freeze

    self.table_name = "system_migration_chains"

    belongs_to :initiated_by_user, class_name: "User", optional: true
    has_many :migrations,
             class_name: "System::Migration",
             foreign_key: :migration_chain_id,
             dependent: :nullify

    attribute :hop_peer_ids, :jsonb, default: -> { [] }
    attribute :audit_log,    :jsonb, default: -> { [] }
    attribute :metadata,     :jsonb, default: -> { {} }

    validates :root_resource_kind, presence: true, length: { maximum: 64 }
    validates :root_resource_id,   presence: true, length: { maximum: 64 }
    validates :operation,          inclusion: { in: OPERATIONS }
    validates :status,             inclusion: { in: STATUSES }
    validates :total_hops,         numericality: { greater_than_or_equal_to: 1 }
    validate  :hop_peer_ids_present_and_unique
    validate  :hop_index_within_range

    scope :active,    -> { where.not(status: TERMINAL_STATUSES) }
    scope :terminal,  -> { where(status: TERMINAL_STATUSES) }

    def terminal?
      TERMINAL_STATUSES.include?(status)
    end

    def can_transition_to?(target)
      TRANSITIONS.fetch(status, []).include?(target.to_s)
    end

    def transition_to!(new_status, audit_entry: nil)
      raise ::ArgumentError, "illegal #{status} → #{new_status}" unless can_transition_to?(new_status)
      attrs = { status: new_status.to_s }
      attrs[:started_at]   = ::Time.current if new_status.to_s == "in_flight" && started_at.nil?
      attrs[:completed_at] = ::Time.current if new_status.to_s == "completed"
      attrs[:failed_at]    = ::Time.current if new_status.to_s == "failed"
      update!(attrs)
      append_audit!(audit_entry) if audit_entry
      self
    end

    def append_audit!(entry)
      update!(audit_log: audit_log + [ entry.merge("at" => ::Time.current.iso8601) ])
    end

    # Returns the hop currently in flight (or queued), or nil when the
    # chain is past its last hop / terminal.
    def current_hop_migration
      return nil if current_hop_index >= total_hops
      migrations.find_by(chain_position: current_hop_index)
    end

    # Returns the peer id for the given hop position. Index 0 is
    # always "self" (the local platform); indices 1..total_hops point
    # at remote peer ids.
    def hop_peer(position)
      hop_peer_ids[position]
    end

    private

    def hop_peer_ids_present_and_unique
      ids = Array(hop_peer_ids)
      errors.add(:hop_peer_ids, "must include at least 2 entries (origin + 1 hop)") if ids.size < 2
      errors.add(:hop_peer_ids, "must be unique") if ids.uniq.size != ids.size
    end

    def hop_index_within_range
      return if current_hop_index.nil?
      return if current_hop_index >= 0 && current_hop_index <= total_hops
      errors.add(:current_hop_index, "must be between 0 and total_hops (#{total_hops})")
    end
  end
end
