# frozen_string_literal: true

module System
  # IMP-c52b5c2d6cbf — ingest for the module-signing ladder's findings.
  #
  # The ladder's audit rungs exist to MEASURE what an enforcing rung would
  # refuse: the agent's verify.AuditVerifier reports
  # `verify:module_signature_audit` and verify.AuditDigestVerifier reports
  # `verify:module_fsverity_audit`, each naming a blob the enforcing mode would
  # have refused. Every finding went to the node's stderr and nowhere else — the
  # service journal, or the initramfs console for the boot composer — so "run
  # audit until the fleet is quiet" meant reading every node's journal by hand,
  # and that is why the ladder's default stayed `off`: neither the default nor
  # any enforcing rung could be a measured decision.
  #
  # WIRE SHAPE (agent/internal/signingaudit.Observation, carried by
  # runtime.HeartbeatPayload#ModuleSigningAudit as `module_signing_audit`):
  #
  #   findings  — one entry per DISTINCT finding, not per report:
  #     stage, detail (the error naming the blob and the reason),
  #     count (repeats since the agent started), first_seen, last_seen
  #   truncated — the node had more distinct findings than its collector keeps
  #
  # The agent de-duplicates because the same finding repeats constantly: a
  # failing attach retries every reconcile tick, and the fs-verity arm checks a
  # newly attached module twice per tick. `count` is therefore the signal for
  # "still happening" — a rising count between heartbeats — while the row itself
  # answers "which blob, and why". A FALLING count means the agent restarted
  # (the counter is per-process), not that the finding cleared; the heartbeat's
  # boot_id is what tells those apart.
  #
  # THREE ABSENCES KEPT APART, for the reason System::RuntimeMetricsWriter and
  # System::BootLkgStateWriter keep theirs:
  #
  #   1. NO `module_signing_audit` BLOCK. Nothing is written and the instance
  #      keeps whatever document it had. This is a node running signing `off`,
  #      or an agent older than this block. It must never read as "clean".
  #   2. THE BLOCK PRESENT, ITS FINDINGS EMPTY. The node measured and had
  #      nothing to report — a pass is running and this node is QUIET. Since
  #      enforcing is justified by the ABSENCE of findings, that is the fact the
  #      whole ladder waits for, so it is recorded as a measurement
  #      (`finding_count` 0), never discarded as "no data".
  #   3. FINDINGS PRESENT. What enforcing would refuse here, today.
  #
  # A MALFORMED BLOCK IS NONE OF THE THREE. It is not an empty measurement:
  # recording it as one would claim the node is quiet on the strength of a
  # report the server cannot read, which is the single most consequential lie
  # this document could tell. Nothing is written.
  #
  # EACH QUALIFYING HEARTBEAT WRITES A FRESH SNAPSHOT, never a merge: a finding
  # the agent stops reporting must DISAPPEAR rather than linger as a stale
  # positive — the defect a frozen "armed" was in BootLkgStateWriter.
  #
  # Delivery covers the SERVICE site only. The boot composer verifies during
  # the initramfs pivot, before any heartbeat exists, so its findings still
  # reach only the console; docs/runbooks/module-signature-verification.md says
  # so where it tells an operator where to look.
  class ModuleSigningAuditWriter
    CONFIG_KEY = "module_signing_audit"

    # The stages this document is allowed to carry. The first two are the audit
    # rungs. The second two are the MEASUREMENT'S OWN FAILURE MODES and belong
    # here for the same reason: `verify:module_signing` means a non-enforcing
    # site had no trust anchor and degraded to NO verification, so a quiet
    # reading from that node is worthless, and `verify:module_signing_keys`
    # means a key refresh failed. A stage outside this list is a producer the
    # server does not understand — storing it would put an unreadable row under
    # a key an operator reads as "signing audit", and a reader gating on the arm
    # would silently mis-count it.
    SIGNING_STAGES = %w[
      verify:module_signature_audit
      verify:module_fsverity_audit
      verify:module_signing
      verify:module_signing_keys
    ].freeze

    # The ladder rungs an observation can come from. WHAT AN EMPTY FINDINGS
    # LIST PROVES DEPENDS ON THE RUNG, because different arms report on each:
    # under `audit` both arms report, so empty means both ran and found
    # nothing; under `runtime` and `all` the signature arm ENFORCES at the
    # service site and constructs no AuditVerifier, so it contributes nothing
    # here and empty means only that the fs-verity arm is quiet. Storing the
    # rung is what lets a reader tell those apart — without it a `runtime` node
    # is indistinguishable from an audited, verified-clean one, and the runbook
    # sends an operator from "clean" to `all`, the rung that turns an unsigned
    # module into an unbootable node.
    #
    # An unrecognized rung is stored as nil rather than guessed: a measurement
    # the server cannot attribute must not be attributable by default.
    LADDER_RUNGS = %w[audit runtime all].freeze

    # Bounds on what a node can put on a platform read surface. The agent caps
    # its own collector (signingaudit.DefaultMaxFindings / MaxDetailChars); this
    # is the server's independent bound, because a hostile or broken agent is
    # exactly the producer these numbers exist for.
    MAX_FINDINGS = 32
    MAX_DETAIL_CHARS = 300
    MAX_STAMP_CHARS = 40
    # A repeat count is a cardinal. Anything outside this range is not a count,
    # and an unbounded Integer is a node writing whatever it likes onto a read
    # surface (a JSON body's `10**400` parses to a Ruby Integer quite happily).
    MAX_COUNT = (2**31) - 1

    class << self
      # Returns the persisted document, or nil when the heartbeat carried no
      # readable block (absence case 1 — nothing is written).
      def write!(instance:, payload:)
        return nil if instance.nil? || payload.nil?
        return nil unless payload.respond_to?(:key?)

        reported = fetch(payload, :findings)
        return nil unless reported.is_a?(Array)

        # One past the cap, so "the node had more than we keep" is a fact rather
        # than an inference from a full list.
        normalized = normalize_findings(reported)
        findings = normalized.first(MAX_FINDINGS)
        document = {
          "observed_at"   => Time.current.utc.iso8601,
          # The rung this measurement came from. nil means the node named a
          # rung the server does not know, so an empty list here attributes to
          # nothing and must not be read as a pass. See LADDER_RUNGS.
          "mode"          => ladder_rung(fetch(payload, :mode)),
          "findings"      => findings,
          "finding_count" => findings.size,
          # Either end may have dropped something. Carried because otherwise
          # finding_count reads as "this node's problems" when it is only the
          # size of the window, and an operator backfilling the named blobs
          # never learns how many went unnamed.
          "truncated"     => fetch(payload, :truncated) == true || normalized.size > MAX_FINDINGS
        }
        merge_config_key!(instance, document)
        document
      end

      private

      # LAZY on purpose. The payload comes from a node: a broken or hostile
      # agent can post 200_000 entries on an endpoint every node hits every 30s.
      # Normalizing the whole array before capping would run a regex and five
      # string copies per entry for rows that are then discarded. Filtering
      # before the cap (rather than capping the raw array first) keeps the
      # property that junk entries cannot push real findings out of the window.
      #
      # This bounds the EXPENSIVE work, not the iteration: entries that fail the
      # stage check are still walked one by one (a hash read and a four-element
      # include?), so a huge payload of junk is O(n) cheaply. The backstop for
      # total size is the shared request-body limit, same as the sibling lanes.
      def normalize_findings(reported)
        reported.lazy
                .select { |entry| entry.respond_to?(:key?) }
                .map { |entry| normalize_finding(entry) }
                .reject(&:nil?)
                .first(MAX_FINDINGS + 1)
      end

      def normalize_finding(entry)
        stage = fetch(entry, :stage).to_s
        return nil unless SIGNING_STAGES.include?(stage)

        {
          "stage"      => stage,
          "detail"     => truncate(fetch(entry, :detail), MAX_DETAIL_CHARS),
          # nil rather than a coerced 1: a count the server cannot read is not
          # a repeat count, and a fabricated one would make "still happening"
          # unfalsifiable.
          "count"      => integer_or_nil(fetch(entry, :count)),
          "first_seen" => truncate(fetch(entry, :first_seen), MAX_STAMP_CHARS),
          "last_seen"  => truncate(fetch(entry, :last_seen), MAX_STAMP_CHARS)
        }
      end

      def fetch(entry, key)
        return nil unless entry.respond_to?(:key?)

        entry[key.to_s].nil? ? entry[key] : entry[key.to_s]
      end

      def ladder_rung(value)
        rung = value.to_s.strip.downcase
        LADDER_RUNGS.include?(rung) ? rung : nil
      end

      def truncate(value, limit)
        return nil if value.nil?

        value.to_s.strip.first(limit).presence
      end

      def integer_or_nil(value)
        return nil unless value.is_a?(Integer) || value.to_s.match?(/\A-?\d{1,19}\z/)

        count = Integer(value)
        count.between?(0, MAX_COUNT) ? count : nil
      rescue ArgumentError, TypeError
        nil
      end

      # config is a SHARED jsonb document written by several telemetry writers
      # in the same request cycle. A read-modify-write here would erase whatever
      # a sibling stored between this request's load and save, so the update
      # touches exactly one key and never reads the rest.
      def merge_config_key!(instance, document)
        ::System::NodeInstance.where(id: instance.id).update_all([
          "config = jsonb_set(COALESCE(config, '{}'::jsonb), ARRAY[?], ?::jsonb, true)",
          CONFIG_KEY, document.to_json
        ])
      end
    end
  end
end
