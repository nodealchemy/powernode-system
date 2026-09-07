# frozen_string_literal: true

# Compiles a network's Sdwan::FirewallRule rows into an `nft -f`-applicable
# script. The script lives in `table inet powernode_sdwan` and uses one
# chain per network (`sdwan_<net-handle>`) — peer interfaces are scoped via
# `iif "<device>"`, where the device is resolved per HOST through
# Sdwan::HostVrfAssignment.wg_iface_name_for and is therefore
# "wg-sdwan-<short_id>" on any host with an assignment. The chain suffix and
# the interface suffix are NOT the same string; do not derive one from the
# other (IMP-54fdf40fbf9d).
#
# Output shape:
#   {
#     table: "powernode_sdwan",
#     chain: "sdwan_019deffa",
#     interface: "wg-sdwan-7",     # or "wg-sdwan-019deffa" with no assignment
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
#     The base-chain `policy` directive itself is ALWAYS emitted as
#     "accept" — it is hook-wide and not scoped by any rule's `iif`
#     clause, so a literal "policy drop" would brick every non-SDWAN input
#     (SSH, agent heartbeats, DNS, ...) on the next reconcile. Allowlist
#     mode is enforced instead via an explicit `iif "<iface>" drop` rule
#     appended after all configured rules — fail-closed for this
#     network's peer interface only, every other interface is unaffected.
#   - Tag-based selectors are no-ops until slice 5 populates nft sets.
#
# Slice 2 of the SDWAN plan.
module Sdwan
  class FirewallCompiler
    TABLE = "powernode_sdwan"
    DEFAULT_POLICY = "accept"
    HOOK_PRIORITY  = 0

    # The RULES are per-network; the `iif` DEVICE is per-host, because
    # Sdwan::HostVrfAssignment allocates a short_id per host+network
    # (IMP-54fdf40fbf9d). This used to discard the peer and answer
    # network-scoped for everything, which is precisely why the emitted iif
    # named a device that host never had. The peer is now threaded through so
    # the interface can be resolved for the host the ruleset is FOR.
    def self.compile_for_peer(peer)
      new(peer.network, peer: peer).compile
    end

    # No peer: callers compiling a network's rules outside a host context
    # (operator preview, multi-tenant composition). Falls back to the handle
    # form, exactly as TopologyCompiler does for a static-only network.
    def self.compile_for_network(network)
      new(network).compile
    end

    def initialize(network, peer: nil)
      @network = network
      @peer    = peer
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

    # The DEVICE, resolved through the single source (the model that owns the
    # name) rather than re-derived from the network handle here.
    #
    # MEMOIZED, and that is load-bearing rather than tidiness: iif_clause calls
    # this once per emitted rule, and TopologyCompiler compiles once per peer on
    # the agent heartbeat path. Unmemoized, a network with P peers and R rules
    # costs P*(R+2) queries per heartbeat.
    def interface_name
      return @interface_name if defined?(@interface_name)

      @interface_name = ::Sdwan::HostVrfAssignment.wg_iface_name_for(
        network: @network, node_instance: @peer&.node_instance
      )
    end

    def default_policy
      policy = @network.settings.fetch("firewall_default_policy", DEFAULT_POLICY)
      %w[accept drop].include?(policy.to_s) ? policy.to_s : DEFAULT_POLICY
    end

    private

    def net_short_id
      @network.network_handle
    end

    def emit_nft_script
      lines = []
      lines << "add table inet #{TABLE}"
      # The base-chain `policy` fires for EVERY packet that reaches this
      # hook — it is not scoped by any rule's `iif` clause, so it must
      # always stay "accept" or every non-SDWAN input (SSH, agent
      # heartbeats, DNS, ...) gets dropped the moment a network is flipped
      # to allowlist mode. Allowlist enforcement happens further down via
      # an explicit iif-scoped deny-all rule instead.
      lines << "add chain inet #{TABLE} #{chain_name} { type filter hook input priority #{HOOK_PRIORITY}; policy accept; }"
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

      # Allowlist mode (firewall_default_policy=drop): append the deny-all
      # AFTER every configured rule, still scoped to this network's
      # interface. Unmatched SDWAN-interface traffic hits this rule and is
      # dropped; unmatched traffic on every other interface never matches
      # any rule in this chain (they're all iif-scoped) and falls through
      # to the chain's accept policy, untouched.
      lines << "add rule inet #{TABLE} #{chain_name} #{iif_clause} drop" if default_policy == "drop"

      lines.join("\n") + "\n"
    end

    # Returns one nft `add rule ...` line, or nil if the rule reduces to a
    # match-nothing case (e.g., a peer_id selector pointing at a deleted peer).
    def emit_rule(rule)
      parts = [ "add rule inet #{TABLE} #{chain_name}", iif_clause ]

      src = ::Sdwan::SelectorResolver.to_nft_match(rule.src_selector, side: :saddr, network: @network)
      dst = ::Sdwan::SelectorResolver.to_nft_match(rule.dst_selector, side: :daddr, network: @network)

      # Fail closed: a selector that restricts to the empty set (deleted peer,
      # tag with no members) drops the whole rule rather than emitting it
      # without that clause (which would match every peer = fail open).
      return nil if src == ::Sdwan::SelectorResolver::MATCH_NOTHING
      return nil if dst == ::Sdwan::SelectorResolver::MATCH_NOTHING

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
