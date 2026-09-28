# frozen_string_literal: true

# The agent-side SDWAN endpoints. The pull side (#config) is the architectural
# pivot from the original task-dispatch design: agents fetch their per-peer
# desired-state on every heartbeat, mirroring how /node_api/config/authorized_keys
# already works. The push side (#report) is how the agent reports actual
# tunnel state — handshake age, peer reachability — back to the platform.
#
# Authentication is via the instance JWT carried on every node_api request
# (handled by the parent NodeApi::BaseController).
#
# Slice 1 of the SDWAN plan.
module Api
  module V1
    module System
      module NodeApi
        class SdwanController < BaseController
          # A reported handshake may sit slightly ahead of platform time
          # (NTP slop between the hub and the platform); anything further
          # ahead is not an observation. See #parse_handshake_time.
          MAX_HANDSHAKE_CLOCK_SKEW = 5.minutes
          RFC3339_ZONE = /(?:Z|[+-]\d{2}:\d{2})\z/

          # `where(id: …)` binds one parameter per id and Postgres caps a
          # statement at 65535 of them. Array(params[:peers]) is uncapped, so
          # the batched lookups slice — a huge batch must stay slow, never
          # become a 500 on an endpoint the agent retries forever.
          ID_QUERY_BATCH = 1_000

          # A byte counter arriving as a string (form-encoded heartbeat) is
          # only a counter if it is unsigned base-10 digits. No sign, no
          # decimal point, no whitespace.
          COUNTER_FORMAT = /\A\d+\z/

          # The widest value a bigint column can hold. The agent carries these
          # as Go int64 so it can never exceed it, but the body is
          # attacker-controllable and ActiveModel raises RangeError on the way
          # to the column — which would 500 an endpoint the agent retries
          # forever. Anything wider is not a kernel counter; it is NOT MEASURED.
          MAX_COUNTER = (2**63) - 1

          # GET /api/v1/system/node_api/config/sdwan
          # Returns one compiled-peer-view per network this instance belongs to.
          # The agent applies these via wgctrl-go on each heartbeat tick.
          #
          # NOTE: action MUST NOT be named `config`. AbstractController::Logger
          # delegates `controller.logger` → `controller.config.logger`, and
          # an action method named `config` shadows that delegate, sending
          # the controller into infinite recursion the moment Rails tries to
          # log anything during render. Route maps GET /config/sdwan → this
          # action via routes.rb.
          def show_config
            instance = current_instance
            peers = ::Sdwan::Peer.includes(:network, :keys)
                                 .where(node_instance_id: instance.id)

            views = peers.map do |peer|
              # include_private_key: true is the whole reason this endpoint
              # exists — the agent needs the private half to drive `wg setconf`.
              # The operator-facing topology endpoint sets it to false so the
              # secret never leaves Vault on the operator path.
              #
              # Federation prefixes are resolved ONCE per network for the
              # request (see federation_resolver). A host with N peers — often
              # all on the same network — would otherwise re-run identical
              # account-scoped FederationPrefixResolver queries inside each
              # TopologyCompiler. The injected resolver memoizes per network so
              # the compiled output is identical while the DB work happens once.
              compiled = ::Sdwan::TopologyCompiler.compile_for_peer(
                peer,
                federation_resolver: request_federation_resolver,
                include_private_key: true
              )
              compiled.merge(network_id: peer.sdwan_network_id, network_cidr_64: peer.network.cidr_64)
            end

            render_success(
              instance_id: instance.id,
              networks: views,
              compiled_at: Time.current.iso8601,
              # Phase N0 — Ed25519 public keys the agent will accept when
              # verifying MC envelopes. Scoped to constellations belonging
              # to this instance's account.
              constellations: trusted_constellations_for(instance),
              # Phase N1a — per-host VRF assignment list, consumed
              # directly by vrf_applier. Includes only assignments in
              # compilable state (active or draining).
              vrf_assignments: vrf_assignments_for(instance),
              # Phase O1 — per-host bridge list, consumed directly by
              # the agent's BridgeApplier. Includes only compilable
              # rows (active or draining).
              host_bridges: ::Sdwan::TopologyCompiler.host_bridges_for(instance),
              # Phase O3 — OVN control-plane endpoints for heavyweight
              # hosts whose account has an active OvnDeployment. nil
              # for lightweight hosts; agent's manager.go treats nil
              # as "OVN not enabled, skip the OVN reconcile step".
              ovn_control: ::Sdwan::TopologyCompiler.ovn_control_for(instance),
              # Phase 3 — the compiled OVN Northbound plan (ls-add /
              # lsp-add / lsp-set-addresses / acl-add) the agent's
              # OvnNbApplier replays against the central NB DB. Top-level
              # (host-scoped) because the agent reads `desired.OvnNbPlan`
              # separately from ovn_control. nil for lightweight hosts or
              # accounts with no active OvnDeployment. Previously absent —
              # the agent's NB applier existed and ran every tick but the
              # server never served the plan, so OVN logical switches +
              # isolation ACLs were never replayed on-host.
              ovn_nb_plan: ::Sdwan::TopologyCompiler.ovn_nb_plan_for(instance)
            )
          end

          # POST /api/v1/system/node_api/status/sdwan
          # Body: { peers: [{ peer_id, last_handshake_at, rx_bytes, tx_bytes, status }, ...] }
          # The agent reports observed tunnel state per peer; we persist
          # last_handshake_at plus the WireGuard byte counters, and recompute
          # peer.status using the active / degraded / disconnected windows
          # defined on Sdwan::Peer.
          #
          # IMP-ab73cc2fca65 — the counters were being measured on-host and
          # shipped in this body from the start, and dropped here. See
          # #peer_observation_columns for the NOT-MEASURED-vs-measured-zero
          # rule and #parse_counter for why they are stored raw and cumulative.
          #
          # IMP-329f2438cc8d — peer_id NAMES THE COUNTERPART, not the
          # reporter's own row. Sdwan::PeerEntry.build's `peer_id: peer.id`
          # (agent/internal/sdwan/manager.go's peerReportsFromActual) reports
          # each REMOTE peer the agent's own WireGuard interface has a live
          # session with — an instance never reports its own peer id in
          # practice. #reportable_peers_by_id scopes to every peer on a
          # network THIS instance itself belongs to (own account), which is
          # exactly the set the agent's compiled config could ever name.
          # Before this, the lookup matched only the reporter's OWN peer
          # rows — a shape the agent never sends — so every real heartbeat's
          # handshake/counters silently vanished behind a 200 `reported: 0`.
          #
          # A hub's compiled view also carries every active user device
          # (HubAndSpoke#hub_view emits `peer_id: <UserDevice#id>`), so the
          # agent reports those ids on the same batch. They are NOT
          # Sdwan::Peer rows, so they fall through to a scoped UserDevice
          # lookup which drives `last_seen_at` (IMP-6fe639b14797). Peer
          # remains the primary lookup — the device path is a fallback only.
          #
          # `reported` counts the entries we RECOGNIZED (a peer on a network
          # we belong to, or a device on a network we hub). An entry we did
          # not recognize is not counted, and a recognized entry carrying no
          # usable handshake is counted but writes nothing.
          #
          # Both lookups are batched. This runs on every agent heartbeat tick
          # for every host in the fleet, so a per-entry query is an N+1
          # multiplied by the fleet — the same trap already fixed in
          # #report_bgp and #vrf_assignments_for below.
          def report
            instance = current_instance
            # The agent retries this heartbeat on failure, so a non-object
            # element (e.g. a bare string) must be skipped, not raise a
            # TypeError on r[:peer_id] and 500 the whole report.
            reports = Array(params[:peers]).select { |r| r.respond_to?(:key?) }
            ids     = reports.filter_map { |r| normalized_peer_id(r[:peer_id]) }.uniq

            peers_by_id   = reportable_peers_by_id(instance, ids)
            devices_by_id = hubbed_devices_by_id(instance, ids - peers_by_id.keys)

            # ONE count query for the whole batch, not one per matched peer
            # (review round, IMP-329f2438cc8d item 1) — #counters_unambiguous_for?
            # only needs "how many peers does THIS network have", and every
            # matched peer's network is already known from peers_by_id. Skipped
            # entirely (not even an empty-array query) when no peer matched at
            # all — a batch of pure user-device reports must not pay for a
            # query nothing in it needs; see sdwan_user_device_liveness_spec's
            # bounded-query-count assertion.
            network_peer_counts =
              if peers_by_id.empty?
                {}
              else
                ::Sdwan::Peer
                  .where(sdwan_network_id: peers_by_id.values.map(&:sdwan_network_id).uniq)
                  .group(:sdwan_network_id)
                  .count
              end

            updated = reports.filter_map do |r|
              id = normalized_peer_id(r[:peer_id])

              if (peer = peers_by_id[id])
                # One write per peer per heartbeat. This runs for every peer on
                # every host in the fleet, so the handshake and the byte
                # counters share a single UPDATE rather than stacking a second
                # one behind the first — see #apply_peer_observation! for why
                # that UPDATE is now conditional SQL rather than a plain
                # update_columns.
                observed = peer_observation_columns(r, peer, network_peer_counts)
                apply_peer_observation!(peer, observed)
                peer.recompute_status_from_handshake!
                { peer_id: peer.id, status: peer.status }
              elsif (device = devices_by_id[id])
                observed = record_device_handshake!(device, r[:last_handshake_at])
                { peer_id: device.id, kind: "user_device", last_seen_at: observed&.iso8601 }
              end
            end

            render_success(reported: updated.size, peers: updated)
          end

          # POST /api/v1/system/node_api/status/bgp
          # Body: {
          #   networks: [
          #     {
          #       network_id: "<uuid>",
          #       router_id: "1.2.3.4",
          #       local_as: 4231866913,
          #       sessions: [
          #         { neighbor_address: "fdf8:...", state: "established",
          #           uptime_seconds: 3600, prefixes_received: 5,
          #           prefixes_sent: 3, last_error: "" }, ...
          #       ]
          #     }, ...
          #   ]
          # }
          # The agent's frr_observer polls `vtysh -c "show bgp summary json"`
          # on each tick and POSTs the deltas. The platform upserts
          # Sdwan::BgpSession rows keyed on (peer, neighbor_address) — these
          # are the canonical "live state" rows the routing dashboard reads.
          #
          # Slice 9f of the SDWAN plan.
          def report_bgp
            instance = current_instance
            networks = Array(params[:networks])

            local_peers = ::Sdwan::Peer.where(node_instance_id: instance.id).to_a
            peer_by_network = local_peers.index_by(&:sdwan_network_id)

            written = ::Sdwan::BgpSessionWriter.new(
              instance: instance,
              peer_by_network: peer_by_network,
              networks_payload: networks
            ).write!

            render_success(reported: written, networks_seen: networks.size)
          end

          private

          # A federation resolver scoped to this request that memoizes the
          # resolved entries per network. Matches the TopologyCompiler
          # `federation_resolver:` lambda contract (`->(network)`), so it
          # drops in transparently and returns byte-identical results to the
          # default Sdwan::FederationPrefixResolver — the only difference is
          # that peers sharing a network resolve the (account-scoped) prefix
          # set once instead of once per peer.
          def request_federation_resolver
            @request_federation_resolver ||=
              begin
                cache = {}
                lambda do |network|
                  key = network&.id
                  next ::Sdwan::FederationPrefixResolver.resolve(network) if key.nil?

                  cache[key] ||= ::Sdwan::FederationPrefixResolver.resolve(network)
                end
              end
          end

          # IMP-ab73cc2fca65 / IMP-329f2438cc8d — the columns ONE heartbeat
          # entry authorizes us to write for a peer.
          #
          # HANDSHAKE: migrated onto the same strict #parse_handshake_time
          # reader the user-device arm already used (see that method's own
          # doc, and record_device_handshake! for the sibling pattern this
          # mirrors) — the ArgumentError-swallowing parse_time this replaced
          # fabricated a fresh handshake (Time.current) on any malformed
          # string, and had NO future-timestamp or monotonic protection at
          # all. Both bounds are enforced here in Ruby, on the INPUT alone:
          # parse_handshake_time itself refuses anything more than
          # MAX_HANDSHAKE_CLOCK_SKEW ahead of now (so a too-far-future value
          # never even reaches this method), and predating the peer's own
          # creation (minus the same skew) is refused the same way a
          # handshake cannot precede the peer existing. What is NOT decided
          # here any more is monotonicity — see #apply_peer_observation! for
          # why that moved to the database.
          #
          # ABSENCE IS THE SIGNAL — FOR THE COUNTERS. A counter this entry did
          # not carry, or carried in a form we cannot trust, contributes NO KEY,
          # so the column keeps whatever it already held. NULL means NOT
          # MEASURED and must stay reachable, because an idle tunnel
          # legitimately reports rx_bytes: 0. "No sample" and "sampled, no
          # traffic" are different facts and a reader has to be able to tell
          # them apart, so nothing here ever writes a placeholder counter.
          #
          # rx and tx move together or not at all. The agent emits both on
          # every entry (state.go PeerStatusReport, no omitempty), so a
          # half-populated pair is not something an honest reporter produces —
          # recording one side of it would publish a counter whose partner is
          # from a different observation, or from none.
          #
          # DIRECTION IS SWAPPED ON WRITE (IMP-329f2438cc8d item 4). The
          # report's rx_bytes/tx_bytes are measured by the REPORTER's own
          # `wg show`, from the REPORTER's perspective of its link to the
          # reported peer — rx is what the reporter received FROM the
          # reported peer, tx is what the reporter sent TO it. But this row
          # is the REPORTED peer's own record, which readers (Peer#
          # observed_traffic, both peer serializers) treat as THAT peer's
          # own rx/tx. The reporter's rx is the reported peer's tx (what it
          # sent, received on the other end) and vice versa, so the columns
          # are swapped here to keep every row in its own subject's
          # perspective regardless of who measured it.
          #
          # COUNTERS AMBIGUITY (IMP-329f2438cc8d): peer_id can now name a
          # COUNTERPART — a different node_instance's row on a network this
          # instance also belongs to (#reportable_peers_by_id) — because
          # that is what the agent actually reports. Both ends of a link
          # report the SAME peer row from opposite vantage points, which is
          # harmless for last_handshake_at (the fresher clock wins,
          # monotonically) but not for a cumulative byte COUNTER: if the
          # reported peer's network holds more than one OTHER peer, more
          # than one distinct reporter can legitimately name it, each with
          # its OWN (rx, tx) pair measured over a DIFFERENT link, and there
          # is no way to tell whose sample a write would be recording. The
          # SAME row would then also flip between two DIFFERENT counterpart
          # links' perspectives from tick to tick, which the swap above
          # cannot fix — it only orients a single, unambiguous link
          # correctly. #counters_unambiguous_for? keeps this simple and
          # conservative rather than deriving hub/spoke cardinality:
          # counters are written only when the network has AT MOST ONE
          # OTHER peer — a genuine point-to-point pair, or the degenerate
          # "no counterpart exists at all" case (which is exactly when the
          # only possible reporter is the peer's own instance). A wider
          # (fan-out) network still gets its handshake/status updated every
          # tick from every reporter; only the byte counters are withheld
          # until the link is unambiguous. network_peer_counts is the whole
          # batch's per-network peer tally, computed once by the caller
          # (#report) rather than one COUNT query per matched peer.
          def peer_observation_columns(report, peer, network_peer_counts)
            columns = {}

            if (observed = parse_handshake_time(report[:last_handshake_at])) &&
               observed >= peer.created_at - MAX_HANDSHAKE_CLOCK_SKEW
              columns[:last_handshake_at] = observed
            end

            if counters_unambiguous_for?(peer, network_peer_counts)
              # Reported from the REPORTER's perspective; swapped below.
              reporter_rx = parse_counter(report[:rx_bytes])
              reporter_tx = parse_counter(report[:tx_bytes])
              if reporter_rx && reporter_tx
                columns[:rx_bytes] = reporter_tx
                columns[:tx_bytes] = reporter_rx
                # The freshness stamp readers need to turn two cumulative
                # samples into a rate. It cannot be inferred from updated_at:
                # the write below deliberately leaves updated_at alone, exactly
                # as the last_handshake_at write always has. A heartbeat is an
                # observation, not an edit — bumping updated_at once a minute for
                # every peer in the fleet would destroy it as a "last changed"
                # signal and fire the model's after_save hooks every tick.
                columns[:counters_sampled_at] = Time.current
              end
            end

            columns
          end

          # See peer_observation_columns' own "COUNTERS AMBIGUITY" doc for
          # the full reasoning; this is the predicate it names.
          # network_peer_counts is keyed by sdwan_network_id, built once per
          # request (#report) — an id absent from it (a network with zero
          # OTHER matched peers this tick doesn't change that network's
          # actual population) defaults to 0, which reads as "count <= 2",
          # matching the single-query-per-request contract: this method
          # itself must never issue a query.
          def counters_unambiguous_for?(peer, network_peer_counts)
            network_peer_counts.fetch(peer.sdwan_network_id, 0) <= 2
          end

          # Writes the columns #peer_observation_columns authorized, as ONE
          # atomic, conditional UPDATE rather than a Ruby read-compare-write
          # (review round, IMP-329f2438cc8d item 3).
          #
          # THE RACE THIS CLOSES: `peer` here is a snapshot from THIS
          # request's own #reportable_peers_by_id lookup. A hub-shaped
          # network can have several concurrent reporters for the SAME row
          # (see the COUNTERS AMBIGUITY doc above), each holding its OWN
          # stale snapshot. Comparing `observed > peer.last_handshake_at` in
          # RUBY and then writing unconditionally — which is what this
          # method replaces — lets two concurrent requests both decide
          # "mine is newer" against their own stale reads and then race at
          # the database; whichever UPDATE commits SECOND wins regardless of
          # which timestamp was actually newer, silently losing the other.
          #
          # GREATEST(last_handshake_at, ?) resolves the compare-and-set
          # INSIDE the single UPDATE statement, atomically, against whatever
          # the column ACTUALLY holds at write time rather than what this
          # request last read — Postgres's GREATEST ignores a NULL argument
          # ("NULL values in the argument list are ignored"), so the
          # never-yet-set case and the monotonic case are the same one
          # expression; no separate nil branch is needed. This is the same
          # pattern already used to close an equivalent race elsewhere on
          # this model (Sdwan::MultiIbgpHostFlagger.merge_key!).
          #
          # update_all bypasses ActiveRecord's attribute cache, so `peer`'s
          # in-memory attributes are stale immediately after this call — the
          # caller's #recompute_status_from_handshake! reads
          # last_handshake_at off that same object, and a status recompute
          # from a stale value would be wrong exactly when the race above
          # actually mattered (a concurrent write landing between this
          # method's UPDATE and the caller's recompute). #reload makes the
          # two consistent with whatever was ACTUALLY committed, which may
          # differ from `columns[:last_handshake_at]` under a concurrent
          # writer — that is the correct outcome, not a bug: GREATEST may
          # have kept the column exactly where a fresher racing write left
          # it, and status must recompute from THAT.
          def apply_peer_observation!(peer, columns)
            return if columns.empty?

            set_clauses = []
            binds = []

            if columns.key?(:last_handshake_at)
              set_clauses << "last_handshake_at = GREATEST(last_handshake_at, ?)"
              binds << columns[:last_handshake_at]
            end

            if columns.key?(:rx_bytes)
              set_clauses << "rx_bytes = ?"
              binds << columns[:rx_bytes]
              set_clauses << "tx_bytes = ?"
              binds << columns[:tx_bytes]
              set_clauses << "counters_sampled_at = ?"
              binds << columns[:counters_sampled_at]
            end

            ::Sdwan::Peer.where(id: peer.id).update_all([ set_clauses.join(", "), *binds ])
            peer.reload
          end

          # A WireGuard byte counter, stored RAW and CUMULATIVE — never
          # differenced here.
          #
          # The kernel restarts a peer's totals at zero whenever the interface
          # is recreated or the peer is re-added, so a sample may legitimately
          # be LOWER than its predecessor. We accept the decrease verbatim: a
          # monotonic guard would pin the counter at its pre-reset high-water
          # mark for the life of the peer, and storing a delta would force this
          # endpoint to guess whether a drop was a reset or a rollback. A
          # reader holding two (value, counters_sampled_at) pairs has what it
          # needs — `newer < older` IS the reset signal, and on a reset the
          # newer value is itself the interval's traffic.
          #
          # What we do NOT accept is a value that cannot have come from the
          # kernel: negatives, floats, non-numeric strings, and anything wider
          # than MAX_COUNTER are not observations, so they leave the columns
          # untouched rather than landing as a fabricated zero. The body is
          # attacker-controllable and the agent retries this heartbeat forever,
          # so a bad value must be inert, never a 500 — and an over-wide
          # integer WOULD have been a 500, because ActiveModel raises
          # RangeError before the value ever reaches Postgres.
          def parse_counter(raw)
            value =
              case raw
              when Integer then raw
              when String  then raw.match?(COUNTER_FORMAT) ? raw.to_i : nil
              end
            return nil if value.nil?
            return nil if value.negative? || value > MAX_COUNTER

            value
          end

          # The batched lookups key rows by the id Postgres returns, which is
          # always canonical. The uuid cast Rails applies inside `where(id:)`
          # accepts far more than that — braces, missing dashes, any case —
          # and canonicalizes, so the old per-entry `find_by` matched all of
          # those spellings. An in-memory hash keyed on the raw request
          # string would not, silently dropping a peer update. Running the
          # request value through the SAME cast the query uses is what keeps
          # batching a pure query-count change; it also yields nil for
          # anything that could never match a uuid column, so junk never
          # reaches the IN list. Both tables' ids are the same uuid type, so
          # one cast serves the peer and device lookups alike.
          def normalized_peer_id(raw)
            return nil unless raw.is_a?(String)

            ::Sdwan::Peer.type_for_attribute(:id).cast(raw)
          end

          # IMP-329f2438cc8d — TENANCY, replacing the old own_peers_by_id
          # (which matched only `node_instance_id: instance.id`, a shape the
          # agent's counterpart reports never carry — see #report's doc).
          #
          # The scope is derived ONLY from the authenticated instance
          # (guidance-executor-tenancy-anchors: an ABSOLUTE anchor, not a
          # check relative to the request body) — every network this
          # instance itself holds a peer on, intersected with its OWN
          # account. That is exactly the set of rows this instance's real
          # WireGuard interfaces could ever hold a live tunnel to: the agent
          # only reports peer ids present in its own compiled config
          # (TopologyCompiler -> Sdwan::PeerEntry.build), and every entry in
          # that config sits on a network the instance is itself a member
          # of. `account_id` is asserted directly rather than trusted
          # transitively through the network join, matching the "absolute,
          # not relative" anchor guidance.
          #
          # An id naming a peer on a network we do NOT belong to (a
          # different account, or simply a network we've never joined)
          # matches nothing here — byte-identical to an id naming no peer
          # at all, so a caller cannot use this to probe for a foreign
          # peer's existence.
          def reportable_peers_by_id(instance, ids)
            return {} if ids.empty?

            network_ids = ::Sdwan::Peer.where(node_instance_id: instance.id)
                                        .distinct
                                        .pluck(:sdwan_network_id)
            return {} if network_ids.empty?

            ids.each_slice(ID_QUERY_BATCH).flat_map { |slice|
              ::Sdwan::Peer.where(account_id: instance.account_id, sdwan_network_id: network_ids, id: slice).to_a
            }.index_by(&:id)
          end

          # IMP-6fe639b14797 — the user-device half of #report.
          #
          # TENANCY: the peer id arrives in the request body and is therefore
          # attacker-controllable. The scope is derived ONLY from the
          # authenticated instance — the set of networks on which it holds a
          # publicly_reachable (hub) peer. That is exactly the set whose
          # compiled views contain user devices at all, so a spoke — or an
          # instance with no peer on the network — matches nothing.
          #
          # An out-of-scope id yields no entry, which is byte-identical to
          # what an id naming nothing at all yields: a caller cannot probe
          # for the existence of devices it does not serve.
          def hubbed_devices_by_id(instance, ids)
            return {} if ids.empty?

            network_ids = hubbed_network_ids(instance)
            return {} if network_ids.empty?

            # `revoked_at: nil` mirrors HubAndSpoke#hub_view's
            # `network.user_devices.active` exactly: the writable set is the
            # set we actually compiled. A revoked device is cut off from the
            # hub, so a report claiming a handshake for one is either stale
            # or fabricated — neither belongs on the revocation audit
            # surface. Grant status is deliberately NOT filtered, because
            # the compiled view does not filter it either.
            # revoked_at is qualified: BOTH joined tables carry that column,
            # and the device is the one we mean.
            devices = ::Sdwan::UserDevice.table_name

            ids.each_slice(ID_QUERY_BATCH).flat_map { |slice|
              ::Sdwan::UserDevice
                .joins(:access_grant)
                .where(devices => { revoked_at: nil, id: slice })
                .where(::Sdwan::AccessGrant.table_name => { sdwan_network_id: network_ids })
                .to_a
            }.index_by(&:id)
          end

          def hubbed_network_ids(instance)
            ::Sdwan::Peer
              .where(node_instance_id: instance.id, publicly_reachable: true)
              .pluck(:sdwan_network_id)
          end

          # ORACLE: last_seen_at means "a WireGuard handshake was OBSERVED at
          # T" — never "a report mentioning this device arrived". It is
          # derived solely from the agent's `last_handshake_at`, which is the
          # kernel's handshake timestamp in RFC3339 and "" when the peer has
          # NEVER handshaked (agent/internal/sdwan/state.go:260,
          # peerReportsFromActual in manager.go). No handshake — or one we
          # cannot parse — is NOT MEASURED, and writes nothing: an operator
          # reading a fresh last_seen_at must be able to conclude the tunnel
          # was actually up at that moment. That conclusion is bounded by
          # "the reporting hub is honest" — the agent IS the sensor here, and
          # nothing cross-checks it. Scoping (hubbed_devices_by_id) bounds the
          # blast radius to devices that hub already serves.
          #
          # parse_handshake_time never falls back to Time.current on a
          # malformed field — that would turn a parse failure into
          # fabricated liveness. Monotonic, so a second hub replaying an
          # older handshake cannot walk a fresher observation backwards.
          # This stays a plain Ruby read-compare-write, unlike the peer arm's
          # #apply_peer_observation! — NOT because multiple hubs reporting
          # the same device is impossible (nothing here enforces a
          # single-hub-per-network invariant), but because closing that race
          # is out of scope for IMP-329f2438cc8d, which touches the peer arm
          # only. Filed as a follow-up rather than fixed here.
          #
          # The device's own creation is the lower bound: a handshake cannot
          # have been observed before the key existed. That is exact — it
          # discards nothing real, unlike an arbitrary age window — and it
          # keeps a wildly out-of-range year (Time.iso8601 happily parses
          # "-5000-01-01T00:00:00Z", which is BELOW the Postgres timestamp
          # floor) away from the write, where it would otherwise raise
          # StatementInvalid and 500 a heartbeat the agent retries forever.
          # The monotonic guard does not cover this: it only fires once
          # last_seen_at is set, and a never-seen device is exactly the
          # normal state of a freshly issued one.
          #
          # Returns the recorded time, or nil when nothing was written.
          def record_device_handshake!(device, raw_handshake)
            observed = parse_handshake_time(raw_handshake)
            return nil if observed.nil?
            return nil if observed < device.created_at - MAX_HANDSHAKE_CLOCK_SKEW
            return device.last_seen_at if device.last_seen_at.present? && device.last_seen_at >= observed

            device.update_columns(last_seen_at: observed, updated_at: Time.current)
            observed
          end

          # Strict RFC3339 with an explicit zone — the wire format the agent
          # emits (`.UTC().Format(time.RFC3339)`). Shared by both handshake
          # consumers (the user-device arm's record_device_handshake! and
          # the peer arm's peer_observation_columns — IMP-329f2438cc8d).
          # Anything else is nil:
          #
          #   ""              the agent's "never handshaked" sentinel
          #   no offset       otherwise silently read in the server's local
          #                   zone, a free time-shift lever on a field the
          #                   caller controls
          #   in the future   a handshake cannot have been observed at a time
          #                   that has not happened. Left unclamped it would
          #                   both advance the handshake column with no
          #                   observation AND — via the caller's monotonic
          #                   guard — pin it there permanently, since every
          #                   honest later report is older. A year past the
          #                   Postgres timestamp ceiling lands here too, so a
          #                   malformed value cannot 500 a heartbeat the
          #                   agent will retry.
          def parse_handshake_time(raw)
            return nil if raw.blank?
            return nil unless raw.is_a?(String) && raw.match?(RFC3339_ZONE)

            observed = Time.iso8601(raw)
            return nil if observed > Time.current + MAX_HANDSHAKE_CLOCK_SKEW

            observed
          rescue ArgumentError, RangeError
            nil
          end

          # Phase N0 — trusted constellation pubkeys for this instance.
          # Currently scoped to the instance's account; cross-account
          # federation trust will extend this in N2 when constellations
          # become first-class.
          def trusted_constellations_for(instance)
            ::Sdwan::ConstellationSigningKey
              .where(account_id: instance.account_id)
              .map do |key|
                {
                  handle: key.handle,
                  public_key_b64: key.public_key_b64
                }
              end
          end

          # Phase N1a — per-host VRF assignments, one entry per network
          # this instance has joined. The agent's vrf_applier consumes
          # this list directly; ordering is irrelevant.
          def vrf_assignments_for(instance)
            assignments = ::Sdwan::HostVrfAssignment
                            .where(node_instance_id: instance.id, state: %w[active draining])
                            .includes(:network)
                            .to_a

            # One query for this instance's peer addresses (grouped by network)
            # instead of net.peers.where(...).pluck per assignment — this runs on
            # the agent heartbeat config pull, so the per-assignment query was an
            # N+1 repeated across the fleet.
            addrs_by_network = ::Sdwan::Peer
                                 .where(node_instance_id: instance.id)
                                 .pluck(:sdwan_network_id, :assigned_address)
                                 .group_by(&:first)
                                 .transform_values { |rows| rows.map { |(_nid, addr)| addr.to_s.split("/").first } }

            assignments.map do |hva|
              net = hva.network
              {
                vrf_name: hva.vrf_name,
                table_id: hva.table_id,
                network_handle: net.network_handle,
                # Phase N1a follow-up — derive bound_iface from the
                # HVA's short_id (single source of truth) so the
                # WG iface name matches the disambiguated VRF name.
                bound_iface: hva.wg_iface_name,
                source_addrs: addrs_by_network.fetch(hva.sdwan_network_id, [])
              }
            end
          end
        end
      end
    end
  end
end
