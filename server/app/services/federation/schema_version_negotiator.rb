# frozen_string_literal: true

module Federation
  # P9.3 — Schema-version negotiator.
  #
  # Resolves the compatibility outcome between this platform's
  # version and a remote peer's reported version. Three resolution
  # tiers, evaluated in order:
  #
  #   1. Operator override row in system_federation_schema_compatibility
  #      with source="operator" — wins regardless.
  #   2. Default seeded row with source="default" — N-1 ladder
  #      bootstrapped at deploy time.
  #   3. Implicit N-1 rule — same major + minor delta ≤ 1 → compatible.
  #      Anything else → incompatible.
  #
  # The result feeds two consumers:
  #   - FederationApi::HeartbeatController stamps peer.platform_version
  #     and uses the outcome to decide whether to advance peer.status.
  #   - Sdwan::FederationGovernance#scan emits peer_schema_version_drift
  #     for pairs whose negotiated status is not "compatible".
  #
  # Plan reference: Decentralized Federation Social Contract #10
  # (N-1 federation compatibility window) + P9.3.
  class SchemaVersionNegotiator
    Result = ::Struct.new(:status, :source, :notes, keyword_init: true) do
      def compatible?
        status == "compatible"
      end

      def incompatible?
        status == "incompatible"
      end
    end

    class << self
      # The platform's own version — read once at boot, cached. Falls
      # back to "0.0.0" if neither VERSION file exists (test/dev edge).
      def current_platform_version
        @current_platform_version ||= read_version_file
      end

      def negotiate(local_version: current_platform_version, remote_version:)
        new(local_version: local_version, remote_version: remote_version).negotiate
      end

      private

      def read_version_file
        candidates = []
        if defined?(::Rails) && ::Rails.root
          candidates << ::Rails.root.join("VERSION")
          candidates << ::Rails.root.join("..", "VERSION")
        end
        candidates.each do |path|
          return ::File.read(path).strip if ::File.exist?(path) && ::File.read(path).strip.length.positive?
        end
        "0.0.0"
      end
    end

    def initialize(local_version:, remote_version:)
      @local  = local_version.to_s.strip
      @remote = remote_version.to_s.strip
    end

    def negotiate
      if @remote.empty?
        return Result.new(status: "incompatible", source: "implicit",
                          notes: "remote peer didn't report a platform_version")
      end

      # Tier 1: operator override.
      override = ::System::FederationSchemaCompatibility.for_pair(@local, @remote)
                                                         .where(source: "operator")
                                                         .first
      return result_from_row(override) if override

      # Tier 2: default seeded row.
      seeded = ::System::FederationSchemaCompatibility.for_pair(@local, @remote)
                                                       .where(source: "default")
                                                       .first
      return result_from_row(seeded) if seeded

      # Tier 3: implicit N-1 rule.
      implicit_n_minus_one
    end

    private

    def result_from_row(row)
      Result.new(status: row.status, source: row.source, notes: row.notes)
    end

    # Implicit N-1: if major matches and |minor delta| ≤ 1, compatible.
    # Otherwise incompatible. Patch version is ignored (patches are
    # always compatible within a minor).
    def implicit_n_minus_one
      local_parts  = parse_semver(@local)
      remote_parts = parse_semver(@remote)
      if local_parts.nil? || remote_parts.nil?
        return Result.new(status: "incompatible", source: "implicit",
                          notes: "unparseable version (local=#{@local.inspect}, remote=#{@remote.inspect})")
      end

      same_major = local_parts[0] == remote_parts[0]
      minor_gap  = (local_parts[1] - remote_parts[1]).abs

      if same_major && minor_gap <= 1
        Result.new(status: "compatible", source: "implicit",
                   notes: "implicit N-1 rule: same major + minor delta #{minor_gap}")
      else
        Result.new(status: "incompatible", source: "implicit",
                   notes: "no compatibility row; major-mismatch or minor delta > 1 (local=#{@local}, remote=#{@remote})")
      end
    end

    # Returns [major, minor, patch] or nil if unparseable.
    def parse_semver(str)
      return nil if str.empty?
      parts = str.split(".")
      return nil if parts.size < 2
      [ parts[0].to_i, parts[1].to_i, parts[2].to_i ]
    rescue ::StandardError
      nil
    end
  end
end
