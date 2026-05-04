# frozen_string_literal: true

# Sdwan::Bgp::RoutePolicyCompiler — translates Sdwan::RoutePolicy rows
# into FRR route-map + prefix-list + as-path-list + community-list
# config blocks. Output is folded into Sdwan::Bgp::ConfigCompiler's
# frr_text and applied per-neighbor via `neighbor X route-map Y in/out`.
#
# Output shape:
#   {
#     # Auxiliary objects (referenced FROM route-maps; emitted BEFORE
#     # route-maps in frr.conf so FRR's parser sees the references resolved):
#     prefix_lists:     ["ip prefix-list pn-XX-1 seq 5 permit 10.0.0.0/24", ...]
#     ipv6_prefix_lists: ["ipv6 prefix-list pn-XX-2 seq 5 permit fd00::/64", ...]
#     as_path_lists:    ["bgp as-path access-list pn-XX-3 permit ^4200000000$", ...]
#     community_lists:  ["bgp community-list standard pn-XX-4 permit 64512:100", ...]
#
#     # Route-maps. Each statement becomes one numbered route-map clause
#     # (seq 10, 20, 30, ...) with the policy's slug as the route-map name.
#     route_maps:       ["route-map pn-policy-foo-import permit 10\n match ip ...\n set local-preference 200", ...]
#
#     # Per-neighbor application directives: which route-maps go on
#     # which neighbor in which direction.
#     #   { neighbor_address => { import: "pn-policy-foo-import", export: "pn-policy-bar-export" } }
#     neighbor_assignments: { ... }
#   }
#
# Slice 9e of the SDWAN plan.
module Sdwan
  module Bgp
    class RoutePolicyCompiler
      def self.compile_for_peer(peer)
        new(peer).compile
      end

      def initialize(peer)
        @peer = peer
        @policies = ::Sdwan::RoutePolicy.applicable_to(peer: peer).to_a
        @prefix_lists = []
        @ipv6_prefix_lists = []
        @as_path_lists = []
        @community_lists = []
        @route_maps = []
        @neighbor_assignments = Hash.new { |h, k| h[k] = {} }
        @aux_counter = 0
      end

      def compile
        if @policies.empty?
          return empty_output
        end

        @policies.each { |policy| compile_policy(policy) }
        assign_to_neighbors

        {
          prefix_lists:        @prefix_lists,
          ipv6_prefix_lists:   @ipv6_prefix_lists,
          as_path_lists:       @as_path_lists,
          community_lists:     @community_lists,
          route_maps:          @route_maps,
          neighbor_assignments: @neighbor_assignments
        }
      end

      private

      def empty_output
        {
          prefix_lists: [], ipv6_prefix_lists: [], as_path_lists: [],
          community_lists: [], route_maps: [], neighbor_assignments: {}
        }
      end

      def compile_policy(policy)
        rm_name = "#{policy.slug}-#{policy.direction}"
        seq = 10
        policy.statements.each do |stmt|
          match  = stmt["match"]  || stmt[:match]  || {}
          action = stmt["action"] || stmt[:action] || {}

          match_lines = compile_match_clauses(policy, match)
          set_lines, terminator = compile_action_clauses(action)

          rm_block = build_route_map_clause(
            name: rm_name, seq: seq, terminator: terminator,
            match_lines: match_lines, set_lines: set_lines
          )
          @route_maps << rm_block
          seq += 10
        end

        # Default-deny tail: if NONE of the policy's clauses matched,
        # FRR's implicit behavior is to deny — but we make it explicit
        # so operators reading frr.conf can see the policy's terminal
        # disposition. v1 ships explicit-deny tail.
        @route_maps << "route-map #{rm_name} deny #{seq}\n!"
      end

      # Compile match.* keys into FRR `match ...` lines. Each match
      # clause that needs auxiliary objects (prefix-list, as-path-list,
      # community-list) gets a uniquely-named one created and recorded.
      def compile_match_clauses(policy, match)
        lines = []

        Array(match["prefix_in"] || match[:prefix_in]).then do |prefixes|
          next if prefixes.empty?

          v4 = prefixes.reject { |p| p.include?(":") }
          v6 = prefixes.select { |p| p.include?(":") }

          if v4.any?
            list_name = aux_name(policy, "p4")
            v4.each_with_index do |cidr, i|
              @prefix_lists << "ip prefix-list #{list_name} seq #{(i + 1) * 5} permit #{cidr}"
            end
            lines << " match ip address prefix-list #{list_name}"
          end

          if v6.any?
            list_name = aux_name(policy, "p6")
            v6.each_with_index do |cidr, i|
              @ipv6_prefix_lists << "ipv6 prefix-list #{list_name} seq #{(i + 1) * 5} permit #{cidr}"
            end
            lines << " match ipv6 address prefix-list #{list_name}"
          end
        end

        if (regex = match["as_path_regex"] || match[:as_path_regex])
          list_name = aux_name(policy, "asp")
          @as_path_lists << "bgp as-path access-list #{list_name} permit #{regex}"
          lines << " match as-path #{list_name}"
        end

        Array(match["community_in"] || match[:community_in]).then do |comms|
          next if comms.empty?

          list_name = aux_name(policy, "comm")
          comms.each do |c|
            @community_lists << "bgp community-list standard #{list_name} permit #{c}"
          end
          lines << " match community #{list_name}"
        end

        Array(match["tag_in"] || match[:tag_in]).each do |tag|
          # FRR `match tag` is numeric only; reject non-numeric silently
          # (validation should catch at the model level).
          next unless tag.to_s.match?(/\A\d+\z/)

          lines << " match tag #{tag}"
        end

        # peer_in is special — FRR doesn't support match-on-peer in
        # route-maps. Operators wanting "this policy applies only when
        # received from peer X" should use scope=peer instead. We log
        # a no-op here so the operator UI can flag the misconfig.
        if Array(match["peer_in"] || match[:peer_in]).any?
          lines << " ! peer_in match unsupported in FRR route-maps; use scope=peer policy instead"
        end

        lines
      end

      def compile_action_clauses(action)
        terminator = (action["type"] || action[:type]).to_s == "reject" ? "deny" : "permit"
        set_lines = []

        if (lp = action["set_local_pref"] || action[:set_local_pref])
          set_lines << " set local-preference #{lp.to_i}"
        end

        if (med = action["set_med"] || action[:set_med])
          set_lines << " set metric #{med.to_i}"
        end

        if (prepend = action["prepend_as_path"] || action[:prepend_as_path])
          # FRR's syntax: `set as-path prepend <as> <as> ...` — repeat
          # the AS N times. Read AS from the peer's account_bgp at
          # compile time.
          if (account_bgp = ::Sdwan::AccountBgp.find_by(account_id: @peer.account_id))
            count = prepend.to_i.clamp(1, 10) # bound so misconfigured policy can't blow up frr.conf
            set_lines << " set as-path prepend #{Array.new(count, account_bgp.as_number).join(' ')}"
          end
        end

        if (comm = action["add_community"] || action[:add_community])
          set_lines << " set community #{comm} additive"
        end

        [set_lines, terminator]
      end

      def build_route_map_clause(name:, seq:, terminator:, match_lines:, set_lines:)
        body = ["route-map #{name} #{terminator} #{seq}"]
        body.concat(match_lines)
        body.concat(set_lines)
        body << "!"
        body.join("\n")
      end

      # Per-neighbor route-map application: walk the policies and for
      # each, decide which neighbors get the policy in which direction.
      # Account- + network-scoped policies attach to every neighbor in
      # the network. Peer-scoped policies attach only to that peer's
      # neighbors. Direction (import vs export) drives `in` vs `out`.
      def assign_to_neighbors
        neighbors = neighbor_addresses_for_peer
        @policies.each do |policy|
          rm_name = "#{policy.slug}-#{policy.direction}"
          target_neighbors = case policy.scope
                             when "account", "network"
                               neighbors
                             when "peer"
                               # Peer-scoped policy only applies if THIS
                               # peer is the scope_resource. (Scope=peer
                               # policies attached to a different peer
                               # were already filtered out by applicable_to.)
                               policy.scope_resource_id == @peer.id ? neighbors : []
                             else
                               []
                             end

          target_neighbors.each do |addr|
            @neighbor_assignments[addr][policy.direction.to_sym] = rm_name
          end
        end
      end

      def neighbor_addresses_for_peer
        # Same neighbor set the ConfigCompiler would emit — every other
        # peer in the network. We strip the /128 mask suffix because
        # FRR neighbors are bare addresses.
        @peer.network.peers.where.not(id: @peer.id)
             .pluck(:assigned_address)
             .map { |a| a.to_s.split("/").first }
      end

      def aux_name(policy, suffix)
        @aux_counter += 1
        "#{policy.slug}-#{suffix}#{@aux_counter}"
      end
    end
  end
end
