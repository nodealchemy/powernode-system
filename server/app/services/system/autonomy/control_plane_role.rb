# frozen_string_literal: true

require "open3"

module System
  module Autonomy
    # Answers one question: "is this control plane the ACTIVE one right now?"
    #
    # RCP v2 runs two ops-hub planes (A and B) with a qnetd witness. Exactly one
    # may actuate; the other must do nothing. With Proxmox HA deliberately not
    # used (see docs/operations/rcp-p1b-consensus-fencing-design.md §6.2 — adding
    # it would have armed the softdog self-fence on the host running the
    # production firewall), NOTHING involuntarily terminates a control-plane VM.
    # This gate is therefore the ONLY thing between a partition and dual-active.
    # It is a safety device, not a convenience, and it is written to fail toward
    # "do nothing".
    #
    # ARMING IS ONE-WAY AND LIVES IN THE DATABASE
    #
    # The gate is inert until the `control_plane_role_coordinator` SiteSetting is
    # set, so a single-plane deployment (today, and core-mode forever) behaves
    # exactly as it did before. That inertness is the dangerous part, and an
    # earlier design left "configured" undefined:
    #
    #   - if armed-ness were inferred from on-host state ("is corosync installed?",
    #     "does /etc/corosync/corosync.conf exist?") then an image re-compose or
    #     pivot that drops an ad-hoc install silently returns BOTH planes to
    #     active. The ops-hub guests are composed A/B-image appliances where
    #     exactly that class of drop is a recorded incident, not a hypothetical.
    #
    # So the marker is a SiteSetting: it lives in the database, survives re-image,
    # and cannot be lost by a composition change. Once armed, an unreadable,
    # stale, or non-quorate reading yields active? == false. It NEVER falls back
    # to inert. Disarming is an explicit operator act (see the runbook in §6.4 of
    # the design), never an inferred one.
    #
    # FRESHNESS IS PART OF THE CONTRACT
    #
    # ControlPlaneFence memoizes its self-id for a whole reconcile pass, which is
    # correct for an identity that cannot change mid-pass. Quorum is the opposite:
    # it changes underneath a running process, and this platform has a recorded
    # bug class where a long-lived poll loop served cached rows for minutes. The
    # same bug here is a split-brain bug, so a reading carries an expiry and an
    # expired reading is treated as no reading at all.
    #
    # A hung process is handled by the same property rather than by a separate
    # mechanism: freshness is PULLED at the point of use, so a plane that is
    # wedged is not confirming anything and therefore is not active. Nothing
    # pushes an "I am active" flag that a stalled updater could leave behind for
    # the gate to read as consent.
    class ControlPlaneRole
      # Presence ARMS the gate. Value is the coordinator's identifier (free-form,
      # e.g. the quorum cluster name) and is not interpreted here.
      COORDINATOR_KEY = "control_plane_role_coordinator"
      # How long a quorum reading may be trusted. Deliberately short: this bounds
      # how long a partitioned-but-alive plane can keep acting on a stale view.
      FRESHNESS_KEY   = "control_plane_role_freshness_seconds"
      DEFAULT_FRESHNESS_SECONDS = 5
      # Upper bound regardless of configuration — an operator cannot widen the
      # split-brain window arbitrarily by setting a large freshness value.
      MAX_FRESHNESS_SECONDS = 30

      QUORUMTOOL = "corosync-quorumtool"
      COMMAND_TIMEOUT_SECONDS = 5

      # One observation of the quorum, with the deadline past which it must not
      # be acted on. Callers doing something irreversible should carry
      # `valid_until` with the plan and re-check before committing, rather than
      # re-deriving activeness from a value they read minutes ago.
      Reading = Struct.new(:quorate, :local_node_id, :member_node_ids, :observed_at, :ttl,
                           keyword_init: true) do
        def valid_until = observed_at + ttl
        def fresh?(now = Time.current) = now < valid_until

        # Lowest node id among the CURRENT quorate membership wins. Deterministic,
        # A-preferred (A holds the lowest id), and consistent with the qnetd
        # `tie_breaker: lowest` setting so the election and the tie-break cannot
        # disagree. Needs no extra configuration to stay in sync.
        def elected?
          return false unless quorate
          return false if local_node_id.nil? || member_node_ids.blank?

          local_node_id == member_node_ids.min
        end
      end

      class << self
        # THE gate. True only when this plane may actuate.
        #
        # Inert (true) while unarmed, so single-plane deployments are unaffected.
        # Once armed, true requires a FRESH reading that is quorate and elects
        # this node. Every other outcome — command missing, command failed,
        # timeout, unparseable output, stale reading, not quorate, not elected —
        # is false.
        #
        # `reading:` lets a caller re-check a reading it is CARRYING rather than
        # taking a new one. That is the point of the freshness check: an
        # irreversible action should capture a reading, carry it with the plan,
        # and re-assert it immediately before committing, so a plan authored
        # while quorate cannot be committed after quorum was lost. Called with no
        # reading, this always observes afresh — in which case the reading is
        # new by construction and the freshness check cannot fire. That is not an
        # argument for deleting it: it is the entire protection on the carried
        # path, and mutation testing caught it being unreachable when `active?`
        # could only ever read for itself.
        def active?(now: Time.current, reading: nil)
          %i[inert active].include?(status(now: now, reading: reading))
        end

        # The gate's verdict WITH its why (IMP-211d8e0fb9e7):
        #   :inert      — unarmed single plane; may actuate.
        #   :active     — armed, fresh quorate reading elects this node.
        #   :standby    — armed and the gate is HEALTHY, but this plane is not
        #                 permitted (not elected, not quorate, stale or
        #                 unreadable quorum — all legitimate stand-downs).
        #   :gate_error — the gate itself raised. This includes a failing
        #                 armed? read, where armed-ness is UNKNOWN — reporting
        #                 "dual-plane armed" there would be a guess, and on an
        #                 unarmed plane an actively misleading one.
        # Fail-closed is unchanged: only :inert/:active permit actuation.
        def status(now: Time.current, reading: nil)
          return :inert unless armed?

          observed = reading || current_reading(now: now)
          return :standby if observed.nil?
          return :standby unless observed.fresh?(now)

          observed.elected? ? :active : :standby
        rescue StandardError => e
          # An unexpected failure in the gate itself must not grant actuation.
          # Logged rather than swallowed silently so a persistently-failing gate
          # is visible as a stood-down plane rather than a mystery.
          Rails.logger.error("[ControlPlaneRole] gate error, standing down: #{e.class}: #{e.message}")
          :gate_error
        end

        # Presence of the marker, read fresh. Not memoized: disarming during an
        # incident must take effect without restarting the process.
        def armed?
          ::SiteSetting.get(COORDINATOR_KEY).present?
        end

        # Pass-scoped amortization (IMP-6ea384a0ee79): return the carried
        # reading while it is still fresh, otherwise observe afresh. A
        # multi-account reconcile pass carries one reading through its loop
        # and pays one quorumtool subprocess per FRESHNESS window instead of
        # one per account — while keeping the freshness contract intact: a
        # reading past its valid_until is never reused, it is replaced.
        def fresh_or_refreshed_reading(carried, now: Time.current)
          return carried if carried&.fresh?(now)

          current_reading(now: now)
        end

        def freshness_seconds
          configured = ::SiteSetting.get(FRESHNESS_KEY).to_i
          return DEFAULT_FRESHNESS_SECONDS unless configured.positive?

          [ configured, MAX_FRESHNESS_SECONDS ].min
        end

        # Observe the quorum now. Returns nil when it cannot be observed — the
        # caller must treat nil as "not active", never as "unchanged".
        def current_reading(now: Time.current)
          out = run_quorumtool
          return nil if out.nil?

          parse_reading(out, now: now)
        end

        # Injection seam for specs and for a future non-corosync substrate (the
        # design names a lease store as the alternative). Returns stdout or nil.
        def quorum_reader
          @quorum_reader ||= method(:corosync_quorumtool_output)
        end

        attr_writer :quorum_reader

        # Restores the production reader. Specs that swap the reader MUST call
        # this in an ensure/after block — a leaked stub would point the live gate
        # at fake quorum data.
        def reset_quorum_reader!
          @quorum_reader = nil
        end

        private

        def run_quorumtool
          quorum_reader.call
        rescue StandardError => e
          Rails.logger.warn("[ControlPlaneRole] quorum read failed: #{e.class}: #{e.message}")
          nil
        end

        # `corosync-quorumtool -s` exits NON-ZERO when the node is inquorate,
        # which is a legitimate answer rather than a failure — so stdout is
        # parsed either way, and only a missing binary or a signal is treated as
        # unreadable. Getting this backwards would turn "definitely not quorate"
        # into "cannot tell", and both must stand down anyway, but the log line
        # would send an operator hunting the wrong problem.
        def corosync_quorumtool_output
          out, _err, status = Open3.capture3(QUORUMTOOL, "-s")
          return out if status.exited?

          nil
        rescue Errno::ENOENT
          Rails.logger.warn("[ControlPlaneRole] #{QUORUMTOOL} not installed — plane stands down")
          nil
        end

        # Parses the `-s` summary. Returns nil rather than a partial Reading if
        # the shape is not what we expect: a half-understood quorum view is
        # exactly the input that should stand a plane down, not one it should
        # guess from.
        def parse_reading(out, now:)
          quorate = out[/^\s*Quorate:\s*(\w+)/i, 1]
          return nil if quorate.nil?

          local_id = out[/^\s*Node ID:\s*(\S+)/i, 1]
          return nil if local_id.nil?

          Reading.new(
            quorate:         quorate.casecmp("yes").zero?,
            local_node_id:   normalize_node_id(local_id),
            member_node_ids: parse_member_ids(out),
            observed_at:     now,
            ttl:             freshness_seconds
          )
        end

        # The membership table lists one row per node; ids may be decimal or the
        # 0x-prefixed form corosync prints in some builds.
        #
        # The QDevice appears here as a member with **node id 0**. It must be
        # excluded from the election: it is a vote, not a candidate. Counting it
        # makes 0 the minimum, so no real node is ever the lowest, BOTH planes
        # stand down, and the control plane is permanently dead — while every
        # symptom looks like the gate correctly failing closed. Caught by a spec
        # written against verbatim `corosync-quorumtool -s` output rather than a
        # trimmed fixture; a tidied-up fixture would have hidden it.
        def parse_member_ids(out)
          section = out[/Membership information.*/mi]
          return [] if section.nil?

          section.scan(/^\s*(0x[0-9a-f]+|\d+)\s+\d+/i)
                 .flatten
                 .filter_map { |id| normalize_node_id(id) }
                 .reject(&:zero?)
        end

        def normalize_node_id(raw)
          s = raw.to_s.strip
          return s.to_i(16) if s.start_with?("0x", "0X")
          return nil unless s.match?(/\A\d+\z/)

          s.to_i
        end
      end
    end
  end
end
