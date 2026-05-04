# frozen_string_literal: true

# Compiles a network's Sdwan::FirewallRule rows into an `nft -f`-applicable
# script. The script lives in `table inet powernode_sdwan` and uses one
# chain per network (`sdwan_<8-char-net-id>`) — peer interfaces are scoped
# via `iif "wg-sdwan-<8-char-net-id>"`.
#
# Output shape:
#   {
#     table: "powernode_sdwan",
#     chain: "sdwan_019deffa",
#     interface: "wg-sdwan-019deffa",
#     policy: "accept" | "drop",
#     rule_count: 5,
#     ruleset: "<full nft script as text — agent applies via `nft -f`>",
#     compiled_at: "2026-05-03T..."
#   }
#
# Atomic-apply contract:
#   add table inet powernode_sdwan        # idempotent
#   add chain inet powernode_sdwan ...    # idempotent (with policy)
#   flush chain inet powernode_sdwan ...  # clear prior rules
#   add rule  ... <rule 1>                # add fresh rules
#   add rule  ... <rule N>
# `nft -f` runs the whole file as a transaction → no partial-state window.
#
# Slice 2 SCOPE notes:
#   - Single hook (input). Egress/output-hook rules ship in slice 5 with a
#     parallel chain `sdwan_egress_<8-char-net-id>`.
#   - Default policy lives on Sdwan::Network.settings["firewall_default_policy"]
#     (defaults to "accept" — operators flip to "drop" for allowlist mode).
#   - Tag-based selectors are no-ops until slice 5 populates nft sets.
#
# Slice 2 of the SDWAN plan.
module Sdwan
  class FirewallCompiler
    TABLE = "powernode_sdwan"
    DEFAULT_POLICY = "accept"
    HOOK_PRIORITY  = 0

    # Convenience: compile one peer's view. The compiled output is per-
    # network (not per-peer), but accepting a peer mirrors how
    # TopologyCompiler is invoked, so callers don't need two shapes.
    def self.compile_for_peer(peer)
      new(peer.network).compile
    end

    def self.compile_for_network(network)
      new(network).compile
    end

    def initialize(network)
      @network = network
      @rules   = network.firewall_rules.enabled.ordered.to_a
    end

    def compile
      {
        table: TABLE,
        chain: chain_name,
        interface: interface_name,
        policy: default_policy,
        rule_count: @rules.size,
        ruleset: emit_nft_script,
        compiled_at: Time.current.utc.iso8601
      }
    end

    # ----------------------------------------------------------------
    # Internal helpers — public for spec coverage.
    # ----------------------------------------------------------------

    def chain_name
      "sdwan_#{net_short_id}"
    end

    def interface_name
      "wg-sdwan-#{net_short_id}"
    end

    def default_policy
      policy = @network.settings.fetch("firewall_default_policy", DEFAULT_POLICY)
      %w[accept drop].include?(policy.to_s) ? policy.to_s : DEFAULT_POLICY
    end

    private

    def net_short_id
      @network.id.to_s.delete("-").first(8)
    end

    def emit_nft_script
      lines = []
      lines << "add table inet #{TABLE}"
      lines << "add chain inet #{TABLE} #{chain_name} { type filter hook input priority #{HOOK_PRIORITY}; policy #{default_policy}; }"
      lines << "flush chain inet #{TABLE} #{chain_name}"

      # The interface scope clause is a global filter for every rule in
      # this chain — without it, a rule on wg-sdwan-AAA would incorrectly
      # match traffic on wg-sdwan-BBB if both interfaces shared the same
      # input chain. By prefixing every rule with `iif "<iface>"` we ensure
      # cross-network isolation at the kernel-routing layer (see slice 1
      # plan section D — "kernel routing — not nftables — provides
      # cross-tenant isolation").
      @rules.each do |rule|
        next unless rule.direction == "ingress" || rule.direction == "both"

        emitted = emit_rule(rule)
        lines << emitted if emitted
      end

      lines.join("\n") + "\n"
    end

    # Returns one nft `add rule ...` line, or nil if the rule reduces to a
    # match-nothing case (e.g., a peer_id selector pointing at a deleted peer).
    def emit_rule(rule)
      parts = ["add rule inet #{TABLE} #{chain_name}", iif_clause]

      src = ::Sdwan::SelectorResolver.to_nft_match(rule.src_selector, side: :saddr)
      dst = ::Sdwan::SelectorResolver.to_nft_match(rule.dst_selector, side: :daddr)
      parts << src if src
      parts << dst if dst

      proto_clause = protocol_clause(rule)
      parts << proto_clause if proto_clause

      port_clause = port_clause(rule)
      parts << port_clause if port_clause

      parts << rule.action

      parts.compact.join(" ")
    end

    def iif_clause
      %(iif "#{interface_name}")
    end

    def protocol_clause(rule)
      case rule.protocol
      when "tcp"   then "tcp"
      when "udp"   then "udp"
      when "icmp6" then "ip6 nexthdr icmpv6"
      else nil
      end
    end

    def port_clause(rule)
      return nil unless %w[tcp udp].include?(rule.protocol)
      return nil if rule.dst_port_range.nil?

      from = rule.dst_port_range.first
      to   = rule.dst_port_range.exclude_end? ? rule.dst_port_range.last - 1 : rule.dst_port_range.last

      if from == to
        "dport #{from}"
      else
        "dport { #{from}-#{to} }"
      end
    end
  end
end
