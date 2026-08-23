# frozen_string_literal: true

# Sdwan::NatCompiler — emits the nft `sdwan_nat_<8>` chain for one
# network: `type nat hook prerouting priority -100` containing one
# DNAT rule per enabled, resolvable Sdwan::PortMapping where this
# peer is the hub.
#
# Output is a Hash with a `ruleset` text field that the agent's
# nat_applier.go writes wholesale to a 0600 tempfile and atomically
# applies via `nft -f`. The chain shares the `inet powernode_sdwan`
# table with the slice 2 filter chain — same atomic apply, no cross-
# table coupling.
#
# Slice 7b of the SDWAN plan.
#
# Campaign 019f3458 increment 6 (hardened DNAT tier): a mapping with
# rate_limit / max_connections / source_cidrs set gets one or more
# GUARD lines emitted immediately before its dnat line, in this fixed
# order: source-cidr filtering, then max_connections, then rate_limit.
# Each guard is a standalone `drop` rule — nft evaluates rules top to
# bottom within a chain, so a dropped packet never reaches the dnat
# line below it, while traffic that clears every guard falls through
# to it unmodified. A mapping with none of the three set contributes
# only its existing single dnat line — zero emission change (see
# nat_compiler_spec.rb's byte-identical-when-unset regression case).
# `rule_count` in the compiled output counts emitted LINES (guards +
# dnat), not mappings — it can now exceed the mapping count.
module Sdwan
  class NatCompiler
    PRIORITY = -100  # nat prerouting; runs before slice 2's forward chain

    def self.compile_for_peer(peer)
      new(peer).compile
    end

    def initialize(peer)
      @peer = peer
      @network = peer.network
    end

    def compile
      mappings = ::Sdwan::PortMapping
                   .enabled
                   .where(sdwan_network_id: @network.id, sdwan_peer_id: @peer.id)
                   .includes(:target_peer, :target_virtual_ip)
                   .to_a

      return empty_output if mappings.empty?

      table = "powernode_sdwan"
      chain = "sdwan_nat_#{network_short_id}"
      rule_lines = []
      skipped = []

      mappings.each do |m|
        target_addr = m.resolved_target_address
        if target_addr.blank?
          skipped << { id: m.id, name: m.name, reason: "target unresolved (VIP unassigned?)" }
          next
        end
        target_port = m.effective_target_port
        rule_lines.concat(guard_lines(m))
        rule_lines << build_rule(m.protocol, m.listen_port, target_addr, target_port)
      end

      ruleset = render_ruleset(table: table, chain: chain, rule_lines: rule_lines)
      {
        table: table,
        chain: chain,
        rule_count: rule_lines.size,
        ruleset: ruleset,
        skipped: skipped,
        compiled_at: Time.current.iso8601
      }
    end

    private

    def empty_output
      { table: "powernode_sdwan", chain: "sdwan_nat_#{network_short_id}",
        rule_count: 0, ruleset: nil, skipped: [], compiled_at: Time.current.iso8601 }
    end

    # nft chain names have no IFNAMSIZ-style length budget (unlike WG
    # interface names), so we slice 8 hex chars directly from the network
    # UUID instead of reusing Network#network_handle (capped at 6 chars
    # so `wg-sdwan-<handle>` fits within Linux's 15-char IFNAMSIZ ceiling).
    # 8 chars = 32 bits of entropy, more than enough per account.
    def network_short_id
      @network.id.to_s.delete("-").first(8)
    end

    # nft DNAT rule. IPv6 addresses are bracketed to disambiguate the port
    # separator, matching the `dnat to [<addr>]:<port>` syntax nft accepts on
    # the wire; v4 addresses are emitted bare.
    #
    # The comment here used to claim "we always bracket for consistency",
    # which the code has never done — it brackets conditionally, and the v4
    # spec (`dnat to 192.0.2.50:5432`) pins the bare form. Corrected in
    # IMP-9537a74e50fa along with routing the expression through the shared
    # Sdwan::HostPort.
    #
    # Unlike the other HostPort consumers, an already-bracketed target is NOT
    # reachable here: target_addr is PortMapping#resolved_target_address, which
    # is either a peer's assigned_address — machine-derived by
    # Sdwan::PrefixAllocator, never operator-settable — or a virtual IP's cidr,
    # whose format validation (/\A[0-9a-f.:]+\/\d{1,3}\z/i) excludes brackets.
    # The shared implementation's double-bracket guard is therefore inert on
    # this path; sharing it is about having one expression, not about a live
    # bug at this site.
    def build_rule(protocol, listen_port, target_addr, target_port)
      "    #{protocol} dport #{listen_port} dnat to #{::Sdwan::HostPort.join(target_addr, target_port)}"
    end

    # Increment 6 hardening: guard lines for one mapping, in the fixed
    # order source-cidrs, max_connections, rate_limit. Returns [] when
    # none of the three are set (the byte-identical-when-unset
    # contract).
    def guard_lines(mapping)
      lines = source_cidr_guard_lines(mapping)
      lines << conn_limit_guard_line(mapping)   if mapping.max_connections.present?
      lines << rate_limit_guard_line(mapping)   if mapping.rate_limit.present?
      lines
    end

    # A single nft match clause can't mix `ip saddr` and `ip6 saddr`
    # literals (a packet is one family or the other), so a mixed-family
    # source_cidrs allow-list compiles to one guard per family: a
    # negated-membership drop for the family that has entries (`saddr
    # != { ... } drop` — only listed sources survive), and a full
    # `meta nfproto <family> drop` for the family that has none (an
    # allow-list naming only v4 CIDRs means v6 traffic is not allowed
    # at all, not silently unrestricted).
    def source_cidr_guard_lines(mapping)
      return [] if mapping.source_cidrs.blank?

      by_family = mapping.source_cidrs_by_family
      proto_dport = "#{mapping.protocol} dport #{mapping.listen_port}"
      lines = []
      lines << if by_family[:v4].any?
                 "    #{proto_dport} ip saddr != { #{by_family[:v4].join(', ')} } drop"
      else
                 "    #{proto_dport} meta nfproto ipv4 drop"
      end
      lines << if by_family[:v6].any?
                 "    #{proto_dport} ip6 saddr != { #{by_family[:v6].join(', ')} } drop"
      else
                 "    #{proto_dport} meta nfproto ipv6 drop"
      end
      lines
    end

    # Standard nftables connlimit idiom: `ct count over N drop` counts
    # concurrent connections sharing this rule's match tuple and drops
    # once the count exceeds N; below the cap the match fails and the
    # packet falls through to the dnat rule.
    def conn_limit_guard_line(mapping)
      "    #{mapping.protocol} dport #{mapping.listen_port} ct count over #{mapping.max_connections} drop"
    end

    # `limit rate over N/second drop` is the negated form of nft's rate
    # limiter — it matches (and this drops) only the traffic that
    # EXCEEDS the budget; traffic within budget doesn't match and falls
    # through to the dnat rule. Rate is stored as a plain
    # requests-per-second integer (see the migration's rationale) so
    # the unit is always the fixed `/second`.
    def rate_limit_guard_line(mapping)
      "    #{mapping.protocol} dport #{mapping.listen_port} limit rate over #{mapping.rate_limit}/second drop"
    end

    def render_ruleset(table:, chain:, rule_lines:)
      <<~NFT
        # Powernode SDWAN — generated by Sdwan::NatCompiler
        # Network #{@network.id} hub #{@peer.id}
        # Slice 7b: hub DNAT for v4-only-client → overlay-service bridging.
        table inet #{table} {
          chain #{chain} {
            type nat hook prerouting priority #{PRIORITY}; policy accept;
        #{rule_lines.join("\n")}
          }
        }
      NFT
    end
  end
end
