# frozen_string_literal: true

# A node-instance's membership in an SDWAN network. The /128 address is
# derived deterministically from the peer's id at create time so that
# operators can read a packet capture and reverse-resolve to a peer row
# without walking a hash. The peer's WireGuard public key lives on the
# associated Sdwan::PeerKey row (Vault-stored private half).
#
# Slice 1 of the SDWAN plan; slice 7a adds dual-stack endpoint columns
# (endpoint_host_v6 / endpoint_host_v4) alongside the legacy endpoint_host.
module Sdwan
  class Peer < ApplicationRecord
    self.table_name = "system_sdwan_peers"

    STATUSES = %w[pending active degraded disconnected].freeze

    # IMP-4ed94eef2971 — the ONE caller-writable field set for a peer UPDATE,
    # read by both surfaces that gate sdwan.peer_update: PeersController#
    # peer_update_params and Ai::Tools::SdwanTool#update_peer. They carried two
    # literal lists and the MCP one was seven fields short, so an agent could
    # not remediate an endpoint or correct a hub election at all.
    #
    # Split by SHAPE because strong parameters needs the shape to permit a
    # non-scalar: an array-declared key drops a non-array and a hash-declared
    # key drops a non-hash, which is what keeps a mis-shaped value out of a
    # `null: false` column on both surfaces. Parity is pinned end-to-end in
    # spec/requests/api/v1/system/sdwan/peer_update_surface_parity_spec.rb —
    # the constant makes the two lists identical by construction, the spec
    # proves each field actually REACHES the executor from both arms.
    #
    # Deliberately NOT the create set: node_instance_id is create-only
    # (CreatePeer::PERMITTED_ATTRIBUTES), and reparenting a live peer is a
    # different action from editing one.
    UPDATE_SCALAR_ATTRIBUTES = %i[
      publicly_reachable
      endpoint_host
      endpoint_host_v6
      endpoint_host_v4
      endpoint_port
      listen_port
      bgp_route_reflector_client
    ].freeze
    UPDATE_ARRAY_ATTRIBUTES = %i[lan_subnets tags].freeze
    UPDATE_HASH_ATTRIBUTES  = %i[capabilities].freeze
    UPDATE_ATTRIBUTES = (UPDATE_SCALAR_ATTRIBUTES + UPDATE_ARRAY_ATTRIBUTES + UPDATE_HASH_ATTRIBUTES).freeze
    HEALTHY_HANDSHAKE_WINDOW = 3.minutes
    DEGRADED_HANDSHAKE_WINDOW = 5.minutes

    belongs_to :network, class_name: "Sdwan::Network", foreign_key: :sdwan_network_id
    belongs_to :node_instance, class_name: "System::NodeInstance"
    belongs_to :account
    has_many :keys, -> { order(created_at: :desc) },
             class_name: "Sdwan::PeerKey",
             foreign_key: :sdwan_peer_id,
             dependent: :destroy
    # Slice 9a — observed advertisements (declared lan_subnets, BGP-learned
    # routes, VIP announcements) all unify here for the operator UI.
    has_many :subnet_advertisements, class_name: "Sdwan::SubnetAdvertisement",
             foreign_key: :sdwan_peer_id, dependent: :destroy
    # IMP 019fe76e-5009: this association was never declared, so peer.destroy!
    # hit the membership-credentials FK and every instance-terminate
    # auto-detach failed — terminated instances left orphaned peers polluting
    # the fabric config (observed on all three dryrun-20260809d teardowns).
    # A membership credential is meaningless without its peer; destroy it too.
    # IMP-2f34679b6b73 — sessions observed FOR this peer, and sessions where
    # this peer is another peer's resolved neighbour. Both FKs are NO ACTION
    # in the baseline schema, so without these `peer.destroy!` raised
    # ActiveRecord::InvalidForeignKey for any peer that had ever been
    # observed — silently breaking Sdwan::Executors::DeletePeer,
    # Sdwan::PeerDetacher, and the Network cascade on exactly the iBGP hosts
    # that carry BGP sessions.
    has_many :bgp_sessions, class_name: "Sdwan::BgpSession",
             foreign_key: :sdwan_peer_id, dependent: :destroy
    # nullify, not destroy: the SESSION belongs to the peer that observed it.
    # Losing the neighbour only loses the FK-resolved name, which is already
    # the nil case Sdwan::BgpSessionWriter#resolve_neighbor_peer_id handles.
    has_many :observed_as_neighbor_sessions, class_name: "Sdwan::BgpSession",
             foreign_key: :neighbor_peer_id, dependent: :nullify
    has_many :membership_credentials, class_name: "Sdwan::MembershipCredential",
             foreign_key: :sdwan_peer_id, dependent: :destroy

    validates :assigned_address, presence: true, uniqueness: { scope: :account_id }
    validates :status, inclusion: { in: STATUSES }
    validates :listen_port, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 65_535 }
    # IMP-4ed94eef2971 — both columns are `null: false` with a `false` default,
    # and both are caller-writable on the two gated update surfaces. Nothing
    # refused an explicit nil, so a caller could park an approval whose only
    # possible outcome was a NOT NULL violation inside the executor, at
    # approval time, in front of an operator who could not see it was doomed
    # when it was submitted (the invariant IMP-785d60f5ec3e established). The
    # validation is on the MODEL rather than in either permit list so both
    # surfaces refuse it the same way, before the gate.
    validates :publicly_reachable, inclusion: { in: [ true, false ] }
    validates :bgp_route_reflector_client, inclusion: { in: [ true, false ] }
    validates :endpoint_port, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 65_535 },
                              allow_nil: true
    # Slice 9a — every entry in lan_subnets must be a valid CIDR (v4 or v6).
    validate :lan_subnets_must_be_cidrs
    # Slice 7a: format-validate the new dual-stack fields. Hostnames are
    # accepted in either column (DNS resolves AAAA/A); literal IPs must
    # match the family of their column.
    validate :endpoint_host_v6_must_be_v6_or_hostname
    validate :endpoint_host_v4_must_be_v4_or_hostname
    validate :hub_must_have_endpoint

    before_validation :allocate_host_address, on: :create
    # D8 — label set used by firewall { "tag": "<label>" } selectors
    # (Sdwan::SelectorResolver). Normalized to a clean, de-duped string array.
    before_validation :normalize_tags
    # Slice 9a — keep Sdwan::SubnetAdvertisement rows in sync when an
    # operator edits lan_subnets. Adds rows for new prefixes, withdraws
    # rows for removed prefixes. Audit trail lives in the advertisement
    # table; lan_subnets is the operator-facing source-of-truth column.
    after_save :sync_subnet_advertisements_from_lan_subnets, if: :saved_change_to_lan_subnets?
    # IMP-2f34679b6b73 — keep the multi-iBGP provenance flag from outliving
    # its condition. Sdwan::PeerEnroller stamps it on the way in, but peers
    # leave by many routes: Sdwan::PeerDetacher, Sdwan::Executors::DeletePeer,
    # several composition skills, and `Sdwan::Network has_many :peers,
    # dependent: :destroy`. Refreshing from the model catches all of them, and
    # the flagger is idempotent so the enroller's explicit call at the
    # enrollment seam stays harmless.
    after_commit :refresh_multi_ibgp_flag, on: :destroy

    scope :hubs,    -> { where(publicly_reachable: true) }
    scope :spokes,  -> { where(publicly_reachable: false) }
    scope :healthy, -> { where(status: "active") }
    scope :online,  -> { where(status: %w[active degraded]) }
    # D8 — peers carrying a firewall tag label (GIN-indexed array containment).
    scope :with_tag, ->(label) { where("tags @> ARRAY[?]::varchar[]", label.to_s) }

    # Returns the peer's currently-active key (un-revoked). Nil until the
    # genesis key is generated by Sdwan::KeyDistributor.ensure_key_for!.
    def active_key
      # `keys` is declared `order(created_at: :desc)`, so the first un-revoked
      # element is the active key. Use the loaded collection (keys.find) rather
      # than keys.where, which issues SQL per peer even when :keys is preloaded —
      # defeating includes(:keys) in the peers index and wg_config_renderer.
      # Matches the topology strategies' idiom.
      keys.find { |k| k.revoked_at.nil? }
    end

    # ---- Slice 7a: dual-stack endpoint resolution ----------------
    #
    # The compiler emits a single Endpoint per [Peer] section (WireGuard
    # protocol limitation), so primary_endpoint picks the v6-preferred
    # candidate. fallback_endpoint returns the v4 alternative if both
    # families are configured — the agent uses it when SdwanReachability
    # sensor flags the primary as dead.
    #
    # Read order: split fields first (slice 7a canonical), then legacy
    # endpoint_host (slice 1) for backward-compat with rows created
    # before the dual-stack migration.

    def primary_endpoint
      return { host: endpoint_host_v6, port: endpoint_port, family: :v6 } if endpoint_host_v6.present? && endpoint_port.present?
      return { host: endpoint_host_v4, port: endpoint_port, family: :v4 } if endpoint_host_v4.present? && endpoint_port.present?
      return nil if endpoint_host.blank? || endpoint_port.blank?

      { host: endpoint_host, port: endpoint_port, family: legacy_endpoint_family }
    end

    def fallback_endpoint
      # Only meaningful when BOTH split fields are populated — that's the
      # explicit "v6 preferred, v4 fallback" topology. If only one is set,
      # there's no alternative to fall back to.
      return nil unless endpoint_host_v6.present? && endpoint_host_v4.present? && endpoint_port.present?

      { host: endpoint_host_v4, port: endpoint_port, family: :v4 }
    end

    def endpoint_candidates
      [ primary_endpoint, fallback_endpoint ].compact
    end

    # Pure "host:port" formatter, bracketing the host only when it is an IPv6
    # LITERAL. Shared by the operator-facing #endpoint_display AND the peer
    # serializers' effective_endpoint — one function, so a readability edit to
    # the operator label can never corrupt the endpoint those surfaces emit.
    # (The DATA-PLANE consumers no longer call this: IMP-915b24d21f4f routed
    # the WireGuard [Peer] Endpoint line through Sdwan::PeerEntry, which calls
    # Sdwan::HostPort.join directly rather than loading a model to format a
    # string.)
    #
    # The bracket cannot be keyed on the tuple's :family —
    # endpoint_host_v6_must_be_v6_or_hostname explicitly accepts a hostname in
    # the v6 column (DNS hands back the AAAA), so a family of :v6 does not imply
    # a literal and "[edge.example.net]:51820" is not an address anyone can use.
    #
    # The same validation also admits an ALREADY-bracketed literal (its literal
    # guard is `include?(":")`, which "[fd00::1]" satisfies), and that is the
    # form an operator pastes out of a WireGuard config — so re-bracketing it
    # blindly yields "[[fd00::1]]:51820".
    #
    # IMP-9537a74e50fa moved the body to Sdwan::HostPort — five other sites had
    # their own copies and three had drifted. This name stays published (its
    # callers are #endpoint_display below plus peers_controller and sdwan_tool)
    # and delegates; the rationale above is why the shared body is shaped the
    # way it is.
    def self.format_host_port(host, port)
      ::Sdwan::HostPort.join(host, port)
    end

    # "host:port" for the primary endpoint (operator-facing label rung).
    # Bracketing rationale lives on .format_host_port.
    def endpoint_display
      endpoint = primary_endpoint
      return nil if endpoint.blank?

      self.class.format_host_port(endpoint[:host], endpoint[:port])
    end

    # The single operator-facing identity for this peer. Both surfaces that name
    # a peer on a destructive operation consume it — the approval card served by
    # the approvals API (Api::V1::System::Sdwan::PeersController#destroy passes
    # it as the gate's `description:`) and the notification body
    # (Sdwan::Executors::DeletePeer#summarize). They each carried their own copy
    # of this expression and drifted; one method is what keeps them honest.
    #
    # The network is part of the identity, not decoration: the unique index is
    # [sdwan_network_id, node_instance_id], so one instance is legitimately a
    # peer in several networks and an instance-name-only label renders identical
    # cards for different destructive operations. The endpoint is the detail
    # rung — used only when the instance carries no operator-facing name.
    def operator_label
      self.class.operator_label_for(
        node_instance: node_instance,
        network_name: network&.name,
        endpoint_display: endpoint_display,
        fallback: id
      )
    end

    # IMP-1eba7d50d24c: the same ladder expressed over the PARTS rather than a
    # persisted row. Sdwan::Executors::CreatePeer#summarize has to name the peer
    # on the approval card BEFORE the row exists, and retyping the ladder there
    # is precisely how the two delete surfaces came to disagree — so the create
    # card composes its label here instead of owning a third format.
    #
    # Returns nil when no rung resolves (a create request that names no instance
    # at all), leaving the choice of degraded sentence to the caller rather than
    # emitting a "label" that is really just the network name.
    def self.operator_label_for(node_instance:, network_name: nil, endpoint_display: nil, fallback: nil)
      identity = node_instance&.name.presence ||
                 node_instance&.discovered_hostname.presence ||
                 endpoint_display.presence ||
                 fallback.presence
      return nil if identity.blank?

      network_name.presence ? "#{identity} on #{network_name}" : identity
    end

    # Recompute status from last_handshake_at. Called by the heartbeat
    # status-report endpoint on every report from the agent.
    def recompute_status_from_handshake!
      now = Time.current
      new_status =
        if last_handshake_at.nil?
          "pending"
        elsif last_handshake_at > now - HEALTHY_HANDSHAKE_WINDOW
          "active"
        elsif last_handshake_at > now - DEGRADED_HANDSHAKE_WINDOW
          "degraded"
        else
          "disconnected"
        end

      update_column(:status, new_status) if new_status != status
      new_status
    end

    # IMP-ab73cc2fca65 — the observed-traffic slice both peer serializers
    # emit. It lives on the model because the two surfaces that publish a peer
    # (Api::V1::System::Sdwan::PeersController#serialize_peer and
    # Ai::Tools::SdwanTool#serialize_peer) are hand-maintained whitelists that
    # have already drifted once — the same failure UPDATE_ATTRIBUTES above was
    # introduced to end. A new column added to only one of them is invisible on
    # the other, which is precisely how a measured signal ends up dark.
    #
    # nil is NOT MEASURED and is published as nil. It is never coerced to 0:
    # an idle tunnel really does report rx_bytes: 0, so a consumer that cannot
    # separate "no sample" from "sampled, no traffic" would read every
    # never-reported peer as an idle one. counters_sampled_at is what makes a
    # rate computable (updated_at cannot serve: the heartbeat writes through
    # update_columns and never bumps it) — the counters are raw cumulative
    # kernel totals, and
    # WireGuard restarts them at zero when the interface is recreated, so a
    # reader differencing two samples must treat `newer < older` as a reset and
    # take the newer value as the interval's traffic.
    def observed_traffic
      {
        rx_bytes: rx_bytes,
        tx_bytes: tx_bytes,
        counters_sampled_at: counters_sampled_at&.iso8601
      }
    end

    # IMP-25e75f960dee — the reset-aware differencing rule stated above, AS
    # CODE, because this is where the second reader will come looking for it.
    # `observed_traffic` publishes RAW CUMULATIVE counters, so every reader
    # that wants an interval figure has to re-derive the same three rules, and
    # a reader that gets any one of them wrong fabricates traffic:
    #
    #   older is nil  -> NO BASELINE. The interval is unmeasurable, so the
    #                    answer is nil, NOT 0. A peer measured for the first
    #                    time has not been observed to move zero bytes; it has
    #                    not been observed over an interval at all.
    #   newer is nil  -> NOT MEASURED this time round. Same answer: nil.
    #   newer < older -> the WireGuard interface was recreated and the kernel
    #                    restarted the counter at zero. The interval's traffic
    #                    is `newer` ITSELF — everything counted since the
    #                    reset. Clamping to 0 loses it; `newer - older` is
    #                    negative and lies about the direction.
    #   otherwise     -> newer - older, which is legitimately 0 for a peer
    #                    that was up and idle.
    #
    # Returns Integer or nil, and the two are DIFFERENT FACTS: 0 is MEASURED
    # AND IDLE, nil is NOT MEASURABLE. A caller that collapses them re-creates
    # exactly the confusion the nullable columns exist to prevent.
    def self.counter_delta(older:, newer:)
      return nil if older.nil? || newer.nil?

      newer < older ? newer : newer - older
    end

    # Returns true when this peer's NodeInstance is running k3s — i.e.
    # the underlying Node has either the `k3s-server` or `k3s-agent`
    # module assigned. Used by the SDWAN routing compilers to decide
    # whether to fold the network's `pod_subnet_prefix` into the peer's
    # BGP announce set + spoke allowed_ips (only k3s peers participate
    # in pod-CIDR routing). Mirrors the predicate pattern in
    # `Api::V1::System::NodeApi::RuntimeController#module_assigned?`.
    def k3s_host?
      return false unless node_instance

      node_instance.node.node_modules.where(name: %w[k3s-server k3s-agent]).exists?
    rescue StandardError
      false
    end

    private

    # See the after_commit above. Best-effort: a peer leaving must not be
    # rolled back because a derived flag could not be refreshed.
    def refresh_multi_ibgp_flag
      ::Sdwan::MultiIbgpHostFlagger.refresh!(node_instance: node_instance_id)
    rescue StandardError => e
      Rails.logger.warn("[Sdwan::Peer] multi-iBGP flag refresh failed for host #{node_instance_id}: #{e.message}")
    end

    def allocate_host_address
      return if assigned_address.present?
      return if sdwan_network_id.blank?

      net = network || Sdwan::Network.find_by(id: sdwan_network_id)
      return unless net

      self.id ||= UUID7.generate
      self.assigned_address = Sdwan::PrefixAllocator.allocate_peer_address!(network: net, peer_id: id)
    end

    def hub_must_have_endpoint
      return unless publicly_reachable
      # Slice 7a: any one of the three endpoint columns satisfies the
      # constraint. Operators can mix-and-match — most will use v6 alone,
      # some will use v4 alone, dual-stack hubs will use both.
      has_endpoint = endpoint_host_v6.present? || endpoint_host_v4.present? || endpoint_host.present?
      errors.add(:base, "publicly_reachable peers need an endpoint (v6, v4, or legacy host)") unless has_endpoint
      errors.add(:endpoint_port, "is required for publicly_reachable peers") if endpoint_port.blank?
    end

    # IPv6 literal: contains colons. Hostname: no colons, has at least
    # one alpha character (so we don't false-positive on a v4 dotted-
    # quad). We accept both shapes in endpoint_host_v6 — DNS hands the
    # family back to wherever the agent ultimately resolves.
    def endpoint_host_v6_must_be_v6_or_hostname
      return if endpoint_host_v6.blank?
      return if endpoint_host_v6.include?(":")       # IPv6 literal
      return if endpoint_host_v6.match?(/[a-zA-Z]/)  # hostname

      errors.add(:endpoint_host_v6, "must be an IPv6 literal or hostname (got what looks like an IPv4 address)")
    end

    def endpoint_host_v4_must_be_v4_or_hostname
      return if endpoint_host_v4.blank?
      return if endpoint_host_v4.match?(/\A(\d{1,3}\.){3}\d{1,3}\z/)                              # IPv4 literal
      return if endpoint_host_v4.match?(/[a-zA-Z]/) && !endpoint_host_v4.include?(":")            # hostname

      errors.add(:endpoint_host_v4, "must be an IPv4 literal or hostname (got what looks like an IPv6 address)")
    end

    def legacy_endpoint_family
      return :v6 if endpoint_host.to_s.include?(":")
      :v4
    end

    # Slice 9a — accept any v4 CIDR or v6 CIDR. We don't enforce
    # non-overlap or non-default-route here; governance scanner (slice 6
    # extension) flags suspicious entries instead.
    def lan_subnets_must_be_cidrs
      Array(lan_subnets).each do |entry|
        next if entry.is_a?(String) && entry.match?(%r{\A[0-9a-f.:]+/\d{1,3}\z}i)

        errors.add(:lan_subnets, "contains an invalid CIDR: #{entry.inspect}")
        break
      end
    end

    # Tags are free-form labels; strip whitespace, drop blanks, de-dup so
    # selector matching ({ "tag": "x" }) is stable and exact.
    def normalize_tags
      self.tags = Array(tags).map { |t| t.to_s.strip }.reject(&:blank?).uniq
    end

    # Slice 9a — diff the new lan_subnets list against existing
    # `declared_lan_subnet` advertisement rows. Add rows for new
    # entries; withdraw (set withdrawn_at) for removed entries.
    def sync_subnet_advertisements_from_lan_subnets
      desired = Array(lan_subnets).map(&:to_s).uniq
      existing_active = subnet_advertisements
                          .where(source: "declared_lan_subnet", withdrawn_at: nil)
                          .pluck(:prefix, :id)

      existing_set = existing_active.map(&:first).to_set
      desired_set  = desired.to_set

      # Withdraw rows whose prefix was removed.
      existing_active.each do |prefix, id|
        next if desired_set.include?(prefix)

        ::Sdwan::SubnetAdvertisement.where(id: id).update_all(withdrawn_at: Time.current, updated_at: Time.current)
      end

      # Add rows for new prefixes.
      (desired_set - existing_set).each do |prefix|
        ::Sdwan::SubnetAdvertisement.create!(
          peer: self,
          network: network,
          account_id: account_id,
          prefix: prefix,
          source: "declared_lan_subnet",
          origin_peer_id: id,
          first_seen_at: Time.current,
          last_seen_at: Time.current
        )
      end
    rescue StandardError => e
      Rails.logger.error("[Sdwan::Peer] subnet-advertisement sync failed for peer #{id}: #{e.class}: #{e.message}")
      # Don't raise — sync failures shouldn't block the peer save.
    end
  end
end
