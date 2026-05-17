# frozen_string_literal: true

module Federation
  # P9.4 — Data residency enforcement for cross-peer operations.
  #
  # Two responsibilities per Social Contract commitment #8:
  #   1. Detect when a migration plan would move data across
  #      residency boundaries.
  #   2. Decide what to do about it: allow + audit, allow + warn,
  #      or refuse. Today's default is "allow + audit" — the migration
  #      proceeds but a `migration.cross_boundary` FleetEvent is
  #      emitted and the migration's audit_log gets a residency entry.
  #
  # An operator can opt into stricter "refuse" semantics by setting
  # ENV["POWERNODE_RESIDENCY_ENFORCEMENT"] = "refuse". The default is
  # permissive because the platform is multi-tenant and many
  # operators don't have residency requirements today.
  #
  # The "local" platform's own residency is resolved from
  # ENV["POWERNODE_DATA_RESIDENCY"] (operator declares once at
  # install) or falls back to "unknown".
  #
  # Plan reference: Social Contract #8 (data residency disclosure).
  class ResidencyEnforcer
    Decision = ::Struct.new(:cross_boundary, :allowed, :reason, :local_residency,
                            :remote_residency, keyword_init: true) do
      def crossed?
        cross_boundary
      end

      def refused?
        !allowed
      end
    end

    PERMISSIVE_MODE = "permissive"
    REFUSE_MODE     = "refuse"

    class << self
      def current_local_residency
        ::ENV["POWERNODE_DATA_RESIDENCY"].presence || "unknown"
      end

      # Default enforcement mode. Operators flip to "refuse" when
      # regulatory boundaries demand hard rejection of cross-region
      # migrations.
      def enforcement_mode
        ::ENV["POWERNODE_RESIDENCY_ENFORCEMENT"].presence || PERMISSIVE_MODE
      end

      # Evaluate a single peer-bound action (e.g. a migration to a
      # specific destination peer). Returns a Decision.
      def evaluate(remote_peer:, local_residency: current_local_residency)
        new(remote_peer: remote_peer, local_residency: local_residency).evaluate
      end
    end

    def initialize(remote_peer:, local_residency:)
      @remote_peer     = remote_peer
      @local_residency = local_residency.to_s.strip
    end

    def evaluate
      remote_residency = @remote_peer&.data_residency.to_s.strip

      # No declared residency on either side → no boundary to cross.
      # Surface this so callers can opt to refuse "unknown" partners.
      if @local_residency.empty? || @local_residency == "unknown" ||
         remote_residency.empty? || remote_residency == "unknown"
        return Decision.new(
          cross_boundary: false, allowed: true,
          reason: "residency not declared (local=#{@local_residency.inspect}, remote=#{remote_residency.inspect})",
          local_residency: @local_residency, remote_residency: remote_residency
        )
      end

      if @local_residency == remote_residency
        return Decision.new(
          cross_boundary: false, allowed: true,
          reason: "same residency (#{@local_residency})",
          local_residency: @local_residency, remote_residency: remote_residency
        )
      end

      # Cross-boundary. Enforcement mode decides outcome.
      allowed = self.class.enforcement_mode != REFUSE_MODE
      Decision.new(
        cross_boundary: true, allowed: allowed,
        reason: "cross-boundary (#{@local_residency} → #{remote_residency}); mode=#{self.class.enforcement_mode}",
        local_residency: @local_residency, remote_residency: remote_residency
      )
    end
  end
end
