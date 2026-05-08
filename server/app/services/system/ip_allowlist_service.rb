# frozen_string_literal: true

module System
  # Generates provider-agnostic security group / firewall rules from an
  # account's (or delegation's) IP allowlist.
  #
  # M4 Enterprise polish — when an Account or Account::Delegation has an
  # explicit IP allowlist configured, all SSH/HTTP/HTTPS access on
  # newly-provisioned cloud instances is restricted to those CIDRs.
  # When no allowlist is configured, the caller falls back to provider
  # defaults (typically "open to 0.0.0.0/0"), preserving the pre-M4
  # behavior.
  #
  # ## Resolution order (highest precedence first)
  #
  # 1. `delegation.ip_allowlist` — per-team override from Slice A's
  #    `account_delegations.ip_allowlist` column. Read defensively via
  #    `respond_to?` so this service ships safely even before Slice A
  #    lands.
  # 2. `account.metadata["ip_allowlist"]` — account-wide allowlist on
  #    the platform-managed metadata bag.
  #
  # The resolution is **additive**: a delegation-level entry adds to
  # account-level entries rather than fully replacing them, so admins
  # don't accidentally lock themselves out of their own infrastructure
  # when scoping a delegated user.
  #
  # ## Output shape
  #
  # Returns an Array of normalized rule Hashes:
  #
  #   { protocol: "tcp", port: 22,  source: "1.2.3.0/24", description: "..." }
  #   { protocol: "tcp", port: 80,  source: "1.2.3.0/24", description: "..." }
  #   { protocol: "tcp", port: 443, source: "1.2.3.0/24", description: "..." }
  #
  # Provider adapters translate this into AWS Security Group rules,
  # Vultr firewall rules, etc. LocalQemu logs and skips (no firewall
  # surface to attach the rules to).
  class IpAllowlistService
    # SSH/HTTP/HTTPS — the platform's standard "remote management +
    # web traffic" port set. Additional ports must be added explicitly
    # via per-template overrides (out of scope for M4).
    DEFAULT_PORTS = [
      { protocol: "tcp", port: 22,  label: "SSH" },
      { protocol: "tcp", port: 80,  label: "HTTP" },
      { protocol: "tcp", port: 443, label: "HTTPS" }
    ].freeze

    # Convenience entry point matching the rest of the System::*
    # service family (`Service.call(...)` / `Service.thing_for(...)`).
    #
    # @param account    [Account]
    # @param delegation [Account::Delegation, nil]
    # @return [Array<Hash>] normalized rules; empty array means
    #   "no allowlist configured — caller should fall back to defaults".
    def self.security_group_rules_for(account:, delegation: nil)
      new(account: account, delegation: delegation).build_rules
    end

    def initialize(account:, delegation: nil)
      @account = account
      @delegation = delegation
    end

    # Returns rules for every (cidr × port) combination, or `[]` when
    # no allowlist is configured. The empty-array return is a deliberate
    # signal to the caller — it preserves "open by default" behavior
    # rather than accidentally locking down instances that pre-date the
    # allowlist feature.
    def build_rules
      cidrs = collect_cidrs
      return [] if cidrs.empty?

      cidrs.flat_map do |cidr|
        DEFAULT_PORTS.map do |spec|
          {
            protocol:    spec[:protocol],
            port:        spec[:port],
            source:      cidr,
            description: "#{spec[:label]} from #{cidr}"
          }
        end
      end
    end

    private

    # Pulls the raw entries off both sources, normalizes each to a
    # CIDR string, drops blanks, and de-duplicates while preserving
    # discovery order (delegation entries first, account second).
    def collect_cidrs
      raw = []
      raw.concat(Array(delegation_allowlist))
      raw.concat(Array(account_allowlist))

      raw.map { |entry| normalize_cidr(entry) }.compact.uniq
    end

    # Defensive read against the delegation column. `respond_to?`
    # keeps this method safe to call before Slice A's migration adds
    # `account_delegations.ip_allowlist`.
    def delegation_allowlist
      return nil unless @delegation
      return nil unless @delegation.respond_to?(:ip_allowlist)
      @delegation.ip_allowlist
    end

    def account_allowlist
      return nil unless @account
      meta = @account.respond_to?(:metadata) ? @account.metadata : nil
      return nil unless meta.is_a?(Hash)
      meta["ip_allowlist"] || meta[:ip_allowlist]
    end

    # Accepts:
    #   "1.2.3.0/24"          → "1.2.3.0/24"
    #   { "cidr" => "..." }   → "..."
    #   { cidr: "..." }       → "..."
    #   ["1.2.3.0/24", "..."] → first element
    #
    # The shape variance is intentional: Slice A may store a richer
    # struct (cidr + label + created_at), and the metadata bag is
    # operator-edited so it can be a flat array of strings. This
    # service is the boundary that flattens both shapes to plain CIDRs.
    def normalize_cidr(entry)
      value =
        case entry
        when Hash
          entry["cidr"] || entry[:cidr]
        when Array
          entry.first
        else
          entry
        end

      return nil if value.nil?
      str = value.to_s.strip
      str.empty? ? nil : str
    end
  end
end
