# frozen_string_literal: true

# IMP-7034199a5a19 — issued user-device configs drift silently.
#
# Sdwan::WgConfigRenderer#allowed_ips widens a client's AllowedIPs to the
# network /64 PLUS every active/pending VirtualIp, every peer's advertised
# lan_subnets, and every federated prefix (IMP-94f3ec671b15 — AllowedIPs is a
# cryptographic routing filter, so a prefix absent from it is one the client OS
# never sends into the tunnel). A NODE peer re-pulls that surface on every
# tick and converges. A USER DEVICE does not: the config is rendered exactly
# once, in Api::V1::System::Sdwan::BootstrapController#show, and
# UserDevice#mark_downloaded! immediately makes the bootstrap URL 410 Gone.
#
# So a VIP or a federation prefix added AFTER a download is missing from every
# previously-issued client for as long as that client keeps its file — silently,
# with no error on either end. The completeness fix repaired this at ISSUE time;
# the same defect recurs continuously POST-issue, and nothing compared the two
# clocks. This sensor is that comparison.
#
# ============================================================================
# NOTIFY-ONLY, AND THE EXEMPTION IS PART OF THE DESIGN
# ============================================================================
# There is no applier and there can be none: the artefact that drifted is a
# text file on a user's laptop, which the platform cannot reach. `skill: nil`,
# `remediation_action: nil` — deliberately NOT the nearest side-effectful
# sdwan_* executor, which would act on plumbing that is fine and be strictly
# worse than an unbound lane. The repair is a human re-issuing the device
# (Sdwan::Executors::CreateUserDevice → a fresh single-use bootstrap URL).
#
# Because the fingerprint therefore stands well past
# RemediationValidator::SETTLE_WINDOW, the category is declared in
# RemediationValidator::NON_REMEDIATING_ACTION_CATEGORIES. Without that entry
# the validate arc scores this lane ineffective every window until the F3-11
# streak manufactures a false fleet.remediation_stuck HIGH escalation and forces
# require_approval — a permanent false alarm that trains operators to ignore the
# lane. Same shape and same reason as system.sdwan_ovn_deployment_investigate
# and system.sdwan_apply_investigate.
#
# ============================================================================
# THE THREE-STATE ORACLE
# ============================================================================
# `last_downloaded_at` carries three distinct facts and each gets its own
# observable position in the payload, because collapsing any two is the failure:
#
#   nil            NEVER DOWNLOADED — `pending_download_count`. No config was
#                  ever issued, so nothing can be stale. nil is NOT infinite
#                  staleness (a SQL `<` on NULL, or a `.to_i` coercion to
#                  epoch 0, would make it maximally stale) and it is NOT
#                  current either.
#   >= changed_at  DOWNLOADED AND CURRENT — `current_device_count`.
#   <  changed_at  DOWNLOADED AND STALE — `stale_devices`. The signal.
#
# The three partitions are disjoint and total over the ACTIVE set.
#
# ============================================================================
# "ACTIVE"
# ============================================================================
# `revoked_at IS NULL` AND the grant is `active`. The recommended action is
# re-issue, and UserDevice#downloadable? gates re-issue on `access_grant.active?`
# — so notifying about a device under a suspended or revoked grant would propose
# an action the operator cannot take, on access they deliberately cut. This is a
# NARROWER set than HubAndSpoke#hub_view compiles (which does not filter grant
# status), and narrower on purpose: a reactivated grant re-enters the set on the
# next tick, so nothing is lost, only deferred.
#
# ============================================================================
# WHY THE FEDERATION ARM IS ANCHORED ON created_at, NOT updated_at
# ============================================================================
# System::FederationPeer#record_heartbeat! is a plain `update!`, so a LIVE
# platform peer bumps its `updated_at` every 60 seconds, forever. Reading
# max(updated_at) there would pin that arm's stamp at ~now on every tick.
#
# READ THE CONSEQUENCE CAREFULLY, because it is the opposite of the obvious
# one: a perpetually-fresh stamp does not alarm, it MUTES. Every stamp must
# clear the settle window to count (#settled_surface_stamps), so an arm stuck
# at ~now never settles and contributes nothing — and if the settle test were
# applied to the MAX instead of per arm, one churning arm would silence the
# other two and this sensor would go permanently dark on exactly the federated
# accounts it matters most for. That is why the window is applied PER ARM, and
# why this arm is anchored on the `created_at` of the CONTRIBUTING peers (the
# exact set Sdwan::FederationPrefixResolver folds into AllowedIPs), which
# covers the case the finding names: a federation peer added after download.
#
# The same trap is not hypothetical on the peer arm either:
# SdwanPeerRemediateExecutor deliberately writes
# `peer.update_columns(..., updated_at: Time.current)` to force a reconcile, so
# a flapping peer moves that stamp on an autonomous lane. Per-arm settling is
# what keeps that from silencing the VIP and federation arms. (On a HUB that
# executor also calls KeyDistributor.rotate!, which genuinely does invalidate
# every issued config — so on hubs the stamp movement is correct, not noise.)
#
# KNOWN GAPS on this arm, deliberately left rather than guessed at: a prefix
# VALUE edited on an existing peer, and a status transition INTO the
# contributing set, both move no created_at and are not detected. Those are
# false negatives, which is the safe side of the trade. Closing them wants
# either a dedicated `federation_prefix_changed_at` stamp on the producer, or a
# rendered-prefix-set snapshot recorded at download time (which would supersede
# this timestamp comparison entirely); both are filed as follow-up work, not
# smuggled in here.
#
# ============================================================================
# WHAT THIS ORACLE STILL OVER- AND UNDER-FIRES ON (all filed, none guessed at)
# ============================================================================
# OVER-FIRES: a VirtualIp failover writes `holder_peer_ids` and bumps
# updated_at without touching `cidr` — the only VIP field the renderer reads —
# so an automated failover can stale a network whose rendered surface did not
# move. The peer arm is narrowed to CONTRIBUTING peers (see #contributing_peers)
# which removes the routine case (enrolling a plain spoke), but an edit to a
# contributing peer's `tags` or `capabilities` still counts.
#
# UNDER-FIRES: a HUB KEY ROTATION is invisible here. Sdwan::KeyDistributor
# .rotate! creates a new Sdwan::PeerKey row and Sdwan::PeerKey's belongs_to
# carries no `touch: true`, so peer.updated_at never moves — yet a re-keyed hub
# breaks every issued config OUTRIGHT, which is strictly worse than a narrowed
# filter. Adding a fourth arm over PeerKey#created_at is the fix; it is a
# different defect class from the AllowedIPs drift this task scoped, so it is
# filed rather than folded in. Removals (a VIP leaving the rendered window, a
# peer deleted, a federation peer suspended) narrow the issued filter and move
# no maximum(), so they are likewise not detected — that is a posture drift,
# not a reachability failure.
module System
  module Fleet
    module Sensors
      class SdwanUserDeviceConfigStalenessSensor < BaseSensor
        # Mirrors Sdwan::WgConfigRenderer#vip_cidrs exactly. A VIP outside this
        # window was never folded into the client's filter, so its edits cannot
        # have drifted anything.
        RENDERED_VIP_STATES = %w[active pending].freeze

        # A burst of related edits (three VIPs, a peer re-key) is one operator
        # action; alarming mid-edit trains people to ignore the lane.
        DEFAULT_SETTLE_AFTER_SECONDS = 900 # 15 minutes

        # How long the drift has to have STOOD before it stops being routine
        # and becomes an escalation. Measured from the surface change, not from
        # the download: it is the un-re-issued interval that hurts.
        DEFAULT_ESCALATE_AFTER_SECONDS = 86_400 # 24 hours

        # One network's worth of stale devices can be large; the count is
        # exact, the sample is capped, and the truncation is stated rather
        # than implied.
        SAMPLE_LIMIT = 25

        SETTING_PREFIX = "system.sdwan.user_device_staleness"
        ACCOUNT_SETTING_PREFIX = "sdwan_user_device_staleness"

        def sense
          return [] unless defined?(::Sdwan::UserDevice)

          rows = candidate_rows
          return [] if rows.empty?

          by_network = rows.group_by { |r| r[:network_id] }
          # account_id is redundant with the join in #candidate_rows and stated
          # anyway — this is the only lookup in the file not scoped by tenancy
          # through its own predicates.
          networks   = ::Sdwan::Network.where(id: by_network.keys, account_id: account.id).index_by(&:id)

          by_network.filter_map do |network_id, network_rows|
            network = networks[network_id]
            next nil if network.nil?

            network_signal(network, network_rows)
          end
        end

        private

        # ONE SIGNAL PER NETWORK, not per device. A single VIP add makes every
        # issued config on that network stale at the same instant — that is ONE
        # fact, and a per-device fingerprint would turn it into a
        # device-count-sized storm of it. The remediation is naturally batched
        # too (re-issue the network's devices). The surface stamp rides the
        # fingerprint, so a LATER mutation is a genuinely new fact and re-fires
        # rather than being squelched by the dedup TTL.
        def network_signal(network, rows)
          surfaces   = settled_surface_stamps(network)
          changed_at = surfaces.values.compact.max
          return nil if changed_at.nil?

          pending    = rows.count { |r| r[:last_downloaded_at].nil? }
          downloaded = rows.reject { |r| r[:last_downloaded_at].nil? }
          stale      = downloaded.select { |r| r[:last_downloaded_at] < changed_at }
          return nil if stale.empty?

          stood_for = (Time.current - changed_at).to_i

          signal(
            kind: "system.sdwan_user_device_config_stale",
            severity: stood_for >= escalate_after_seconds ? :high : :medium,
            payload: {
              "network_id"   => network.id,
              "network_name" => network.name,
              # WHEN the routable surface last moved, and WHICH of the three
              # sources moved it — an operator needs the cause, not just the
              # verdict.
              "surface_changed_at"        => changed_at.iso8601,
              "surface_stale_for_seconds" => stood_for,
              "changed_surfaces"          => surfaces.transform_values { |t| t&.iso8601 },
              # State 3 — the signal.
              "stale_device_count"      => stale.size,
              "stale_devices"           => stale.first(SAMPLE_LIMIT).map { |r| device_entry(r, changed_at) },
              "stale_devices_truncated" => stale.size > SAMPLE_LIMIT,
              # States 1 and 2 — each in its own field, so neither can be read
              # as the other or as staleness.
              "pending_download_count" => pending,
              "current_device_count"   => downloaded.size - stale.size,
              # The human action. NOT a remediation_action: nothing the fleet
              # can execute reaches a config file on a user's laptop, and
              # borrowing the nearest side-effectful executor to fill this
              # field would be worse than leaving the lane unbound.
              "recommended_action" => "reissue_user_device_config",
              "remediation_action" => nil
            },
            fingerprint: "sdwan_user_device_config_stale:#{network.id}:#{changed_at.to_i}"
          )
        end

        def device_entry(row, changed_at)
          {
            "device_id"          => row[:id],
            "label"              => row[:label],
            # The grant holder to notify.
            "user_id"            => row[:user_id],
            "last_downloaded_at" => row[:last_downloaded_at].iso8601,
            # Liveness CONTEXT, never a gate (IMP-6fe639b14797). An offline
            # laptop still holds a stale file, so a nil here must not suppress
            # the signal — and a fresh handshake must not excuse it either.
            "last_seen_at"       => row[:last_seen_at]&.iso8601,
            "stale_by_seconds"   => (changed_at - row[:last_downloaded_at]).to_i
          }
        end

        # PER ARM, never on the max. A burst of related edits is one operator
        # action and should not alarm mid-edit — but an arm with a churning
        # writer (see the header on record_heartbeat! and on
        # SdwanPeerRemediateExecutor) would, if the window were applied to the
        # max, hold the whole network permanently inside it and silence the
        # other two arms for good. An unsettled arm simply does not count yet.
        def settled_surface_stamps(network)
          cutoff = settle_after_seconds.seconds.ago
          surface_stamps(network).transform_values { |t| t && t <= cutoff ? t : nil }
        end

        # The three sources Sdwan::WgConfigRenderer#allowed_ips folds in, each
        # reduced to the stamp of its last surface-affecting change. nil means
        # "this source contributes nothing", never "unchanged".
        def surface_stamps(network)
          {
            "virtual_ips"         => network.virtual_ips.where(state: RENDERED_VIP_STATES).maximum(:updated_at),
            "peers"               => contributing_peers(network).maximum(:updated_at),
            "federation_prefixes" => federation_stamp
          }
        end

        # Only peers that put something INTO a user device's config. The
        # renderer reads exactly two things off a peer: every peer's
        # `lan_subnets` (#advertised_lan_subnets) and a publicly-reachable
        # peer's key + endpoint (the [Peer] sections). A plain spoke with no
        # advertised subnets contributes literally nothing, so enrolling one —
        # a routine provisioning event on any growing network — must not mark
        # every issued config on that network stale.
        def contributing_peers(network)
          network.peers.where("cardinality(lan_subnets) > 0 OR publicly_reachable = TRUE")
        end

        # Account-scoped (the resolver's own scope), so it is computed once and
        # reused across every network in the account rather than per network.
        # created_at, not updated_at — see the header.
        def federation_stamp
          return @federation_stamp if defined?(@federation_stamp)

          @federation_stamp =
            if defined?(::System::FederationPeer)
              ::System::FederationPeer
                .federation_prefix_contributing
                .where(account_id: account.id)
                .where.not(remote_prefix_advertisement: [ nil, "" ])
                .maximum(:created_at)
            end
        end

        # Batched and plucked: this runs for every account on every fleet tick,
        # and instantiating a model per device (plus its grant) would be an N+1
        # multiplied by the device count. Ordered oldest-download-first so the
        # capped sample shows the worst drift, with the never-downloaded rows
        # last (NULLS LAST) rather than sorting as epoch 0.
        def candidate_rows
          devices  = ::Sdwan::UserDevice.table_name
          grants   = ::Sdwan::AccessGrant.table_name
          networks = ::Sdwan::Network.table_name

          ::Sdwan::UserDevice
            .joins(access_grant: :network)
            .where(devices => { revoked_at: nil })
            .where(grants => { status: "active" })
            .where(networks => { account_id: account.id })
            # Sdwan::Network.compilable's window. A suspended or archived
            # network is one nobody will re-issue into, so its devices are not
            # a call to action — they are noise on a network being torn down.
            .where(networks => { status: %w[registered active] })
            .order(Arel.sql("#{devices}.last_downloaded_at ASC NULLS LAST"))
            .pluck("#{grants}.sdwan_network_id", "#{devices}.id", "#{devices}.label",
                   "#{devices}.last_downloaded_at", "#{devices}.last_seen_at",
                   "#{grants}.user_id")
            .map do |network_id, id, label, downloaded_at, seen_at, user_id|
              { network_id: network_id, id: id, label: label,
                last_downloaded_at: downloaded_at, last_seen_at: seen_at, user_id: user_id }
            end
        end

        def settle_after_seconds
          @settle_after_seconds ||= tuned("settle_after_seconds", DEFAULT_SETTLE_AFTER_SECONDS)
        end

        def escalate_after_seconds
          @escalate_after_seconds ||= tuned("escalate_after_seconds", DEFAULT_ESCALATE_AFTER_SECONDS)
        end

        # DB-driven, account first then SiteSetting then the constant — the
        # same precedence every other sdwan_* sensor uses. A non-positive or
        # unparseable value falls back rather than disabling the window.
        def tuned(key, default)
          raw = account.settings&.dig("#{ACCOUNT_SETTING_PREFIX}_#{key}").presence ||
                ::SiteSetting.get("#{SETTING_PREFIX}.#{key}")
          value = raw.to_i
          value.positive? ? value : default
        end
      end
    end
  end
end
