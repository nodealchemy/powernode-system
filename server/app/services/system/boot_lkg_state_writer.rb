# frozen_string_literal: true

module System
  # IMP-b8d5cfa33b79 — ingest for the agent's BOOT / LKG (last-known-good)
  # telemetry.
  #
  # The agent has emitted seven boot/LKG fields on EVERY heartbeat since #39
  # (agent/internal/runtime/heartbeat.go, populated in service.go) and ZERO
  # server code read any of them. That is the same half-lane shape
  # Sdwan::AgentApplyStateWriter and System::ModuleVerifyStateWriter closed: a
  # producer whose payload nothing consumes is invisible to unit specs on both
  # sides, because both pass while the wire between them is cut.
  #
  # WIRE SHAPE (runtime.HeartbeatPayload — SEVEN TOP-LEVEL SCALAR KEYS, not a
  # nested block like the two sibling lanes):
  #
  #   lkg_present, lkg_confirmed_at, lkg_module_count   — ARM telemetry (HIGH-1):
  #     emitted on every boot from the on-disk frozen LKG, so an operator can
  #     VERIFY a node is armed with a valid last-known-good BEFORE #14 pulls its
  #     control plane.
  #   booted_from_lkg, lkg_age_seconds                  — did THIS boot fall back
  #     to the frozen composition, and how stale was it.
  #   boot_incomplete                                   — this boot composed an
  #     incomplete assigned set (a data module was dropped at compose).
  #   pivot_confinement_omitted                         — confinements the
  #     direct_kernel/pivot boot path does NOT enforce.
  #
  # == THE ABSENCE RULE, AND WHY IT IS THE WHOLE POINT
  #
  # Every one of those fields is Go `omitempty`. A false or zero value is
  # therefore NOT TRANSMITTED AT ALL: on the wire, "false" and "the agent is too
  # old to have the field" are the same bytes. The producer states the reading
  # explicitly — "Absence of lkg_present=true means 'not armed'".
  #
  # So a missing key is ingested as UNREPORTED, never as a measured `false`:
  #
  #   * `arm_state` is "armed" ONLY when lkg_present arrived explicitly true.
  #     Anything else — absent, false, unparseable — is "unreported", which a
  #     decommission gate must treat as BLOCKING. Reading absence as "armed"
  #     would convert a decommission blocker into a decommission green light,
  #     strictly worse than the status quo where the operator at least knows
  #     the answer is missing.
  #   * `lkg_present` / `booted_from_lkg` / `boot_incomplete` are stored as
  #     `true` or `nil` and NEVER as `false`. A stored `false` would assert a
  #     negative the node never stated. For the same reason
  #     `pivot_confinement_omitted` is stored as a list or `nil`, never as `[]`:
  #     an empty list reads as "nothing omitted, fully confined", which is the
  #     array-shaped version of exactly that fabricated negative.
  #
  # == WHY ABSENCE DOES NOT STAY ABSENCE ONCE A NODE HAS REPORTED
  #
  # The two sibling lanes write nothing when their block is missing, full stop.
  # That is right for them and WRONG here, because this lane's absence is not
  # only "an old agent": a CURRENT agent whose on-disk LKG was deleted, wiped by
  # a re-provision, or corrupted emits NONE of the seven (service.go's
  # LoadBootLKG error path plus `omitempty` on every remaining false/zero). If
  # such a heartbeat left the previous document untouched, a node that WAS armed
  # would keep answering `arm_state: "armed"` forever after it stopped being
  # armed — the decommission green light this class exists to prevent, reached
  # through time instead of through a single payload.
  #
  # So the rule is:
  #
  #   * NO document yet AND none of the seven keys ⇒ write NOTHING. A pre-#39
  #     agent (much of the deployed fleet) leaves no document, which reads as
  #     "never reported" and is distinct from every reported state.
  #   * A document ALREADY EXISTS ⇒ REWRITE IT on every heartbeat, even one
  #     carrying none of the seven. The stored answer is then never older than
  #     the last heartbeat, and an LKG that disappears flips `arm_state` to
  #     "unreported" on the very next tick.
  class BootLkgStateWriter
    # Where the document lands on System::NodeInstance#config. A jsonb key
    # rather than a column, for the same reason the two sibling lanes are: this
    # is per-tick telemetry whose shape follows the agent's wire format, and
    # putting a migration in front of a consumer-side fix helps nobody.
    CONFIG_KEY = "boot_lkg"

    # The exact keys read off the heartbeat. Also the first-write oracle: none
    # of them present, and no document yet, means no document at all.
    WIRE_KEYS = %w[
      booted_from_lkg lkg_age_seconds lkg_present lkg_confirmed_at
      lkg_module_count boot_incomplete pivot_confinement_omitted
    ].freeze

    # Caps. The payload arrives from a node — a compromised or simply buggy
    # agent can make it as large as it likes — and lands in a jsonb column read
    # on every fleet read.
    MAX_CONFINEMENTS     = 32
    # Stated once in System::IdentifierCaps — same bound, different write surface.
    MAX_IDENTIFIER_CHARS = ::System::IdentifierCaps::MAX_IDENTIFIER_CHARS
    # Digits, not value: the two numeric fields are an int64 and an int on the
    # producer, and an unbounded integer literal is ~130KB per field per tick of
    # jsonb growth that the controller's rescue would swallow silently.
    MAX_INTEGER_DIGITS   = 19

    ARMED      = "armed"
    UNREPORTED = "unreported"

    # Only an EXPLICIT truth is truth. Nothing falsy, absent or unparseable can
    # reach `true` through this set — which is the one direction that would
    # matter.
    TRUTHY = %w[true 1 t yes].freeze

    class << self
      # Returns the persisted document, or nil when nothing was written (see
      # the two rules in the class doc).
      def write!(instance:, payload:)
        return nil if instance.nil?

        readable = payload.respond_to?(:key?) ? payload : nil
        document = build_document(readable)
        # Which of the two rules applies is decided IN THE STATEMENT, not from
        # `instance.config`: the previous document was written with update_all,
        # so an in-memory read is only as fresh as whenever this object was
        # last loaded — and being wrong in the stale direction is precisely the
        # "still says armed" failure this lane exists to prevent.
        written = merge_config_key!(instance, document, allow_first_write: reported_anything?(readable))
        written ? document : nil
      end

      private

      # `!nil?`, not `.present?`: an explicit `lkg_present: false` IS a report
      # (it just cannot be distinguished from the omission that would produce
      # the same bytes), and it must still leave a document saying "unreported"
      # rather than nothing at all.
      def reported_anything?(payload)
        return false if payload.nil?

        WIRE_KEYS.any? { |key| !fetch(payload, key).nil? }
      end

      def build_document(payload)
        present = true_or_nil(fetch(payload, :lkg_present))

        {
          # When the report REACHED us. Deliberately separate from
          # `lkg_confirmed_at`, which is the AGENT's clock for the on-disk LKG:
          # a node whose LKG froze keeps re-shipping the same confirmed_at,
          # which the server would otherwise re-stamp as fresh every tick. This
          # is also the freshness oracle for the rewrite rule above — it moves
          # on every heartbeat, so a stale document is detectable.
          "observed_at" => Time.current.utc.iso8601,

          # DERIVED, and the field a decommission gate reads. "armed" requires
          # an explicit lkg_present=true; everything else is "unreported".
          "arm_state"        => present ? ARMED : UNREPORTED,
          "lkg_present"      => present,
          "lkg_confirmed_at" => timestamp_or_nil(fetch(payload, :lkg_confirmed_at)),
          "lkg_module_count" => integer_or_nil(fetch(payload, :lkg_module_count)),

          # This boot. nil means unreported — NOT "booted normally": an agent
          # predating #39 emits the identical absence while surviving on a
          # frozen composition.
          "booted_from_lkg" => true_or_nil(fetch(payload, :booted_from_lkg)),
          "lkg_age_seconds" => integer_or_nil(fetch(payload, :lkg_age_seconds)),
          "boot_incomplete" => true_or_nil(fetch(payload, :boot_incomplete)),

          # A list, or nil. The producer declares its own absence as "full set
          # enforced (or not a pivot node)", but that reading only binds agents
          # that HAVE the field — an older one emits the identical absence, and
          # storing `[]` for it would claim full confinement on a pivot node
          # with live gaps. nil says "unreported" and makes that misread
          # impossible, at the cost of a distinction the wire never carried.
          "pivot_confinement_omitted" => normalize_confinements(fetch(payload, :pivot_confinement_omitted))
        }
      end

      # nil unless the wire carried a genuinely non-empty list. The cap can only
      # ever SHRINK a list whose entries are alarming (each names a confinement
      # NOT in force), so truncation cannot paint a node greener than it is —
      # though 32 junk names WOULD push the real entries out of the window, so
      # the list bounds the alarm, not the identity of the gap.
      def normalize_confinements(raw)
        return nil unless raw.is_a?(Array)

        normalized = raw
          .first(MAX_CONFINEMENTS)
          .map do |value|
            # A blank entry is KEPT under a name that says so. Dropping it would
            # silently shorten the omission list, which is the one direction
            # that understates how little the node enforces.
            identifier(value).presence || "unnamed"
          end
        normalized.empty? ? nil : normalized
      end

      # true or nil — never false. See the class doc: `omitempty` makes a
      # transmitted false impossible, so a stored false would be a negative the
      # node never asserted.
      def true_or_nil(raw)
        TRUTHY.include?(raw.to_s.downcase) ? true : nil
      end

      # Tries BOTH forms regardless of which the caller passed. The two sibling
      # writers only ever see an ActionController::Parameters (indifferent
      # access), so their string-only fallback is enough for them; this class is
      # also called with plain hashes, and a symbol-keyed one silently reading
      # as "reported nothing" would be a false green.
      def fetch(entry, key)
        return nil if entry.nil?

        value = entry[key.to_sym]
        value.nil? ? entry[key.to_s] : value
      rescue TypeError, NoMethodError
        nil
      end

      def integer_or_nil(raw)
        return nil if raw.nil?
        return nil unless raw.to_s.strip.match?(/\A-?\d{1,#{MAX_INTEGER_DIGITS}}\z/o)

        raw.to_s.strip.to_i
      end

      # Re-emitted as normalized UTC rather than echoed: this field is PARSED by
      # its consumers, not displayed, and an unparseable value is an unmeasured
      # one — the same rule the sibling writers apply to an unrecognized state
      # string. Also the only free-text field a node controls here, so parsing
      # it is what keeps junk (NUL bytes included) out of the jsonb column.
      def timestamp_or_nil(raw)
        return nil if raw.nil?

        value = raw.to_s
        return nil if value.empty? || value.length > MAX_IDENTIFIER_CHARS

        Time.iso8601(value).utc.iso8601
      rescue ArgumentError, TypeError
        nil
      end

      def identifier(raw)
        return nil if raw.nil?

        value = raw.to_s
        value.length > MAX_IDENTIFIER_CHARS ? value[0, MAX_IDENTIFIER_CHARS] : value
      end

      # Sets ONE top-level key without reading the rest of the document first —
      # `config` is written from several request cycles (the operator API, the
      # status report endpoint, the cloud_instance_id store accessors), and a
      # read-modify-write of the whole jsonb from this per-tick path would
      # silently erase whatever another writer put there in the interval. Same
      # idiom as Sdwan::AgentApplyStateWriter.merge_config_key!, plus one guard
      # those two do not need: without `allow_first_write` the UPDATE only
      # matches a row that ALREADY carries the key, which is how "refresh an
      # existing document, but never create one from a heartbeat that reported
      # nothing" is expressed atomically. Returns whether a row was written.
      def merge_config_key!(instance, document, allow_first_write:)
        scope = ::System::NodeInstance.where(id: instance.id)
        scope = scope.where("config -> ? IS NOT NULL", CONFIG_KEY) unless allow_first_write

        scope.update_all([
          "config = jsonb_set(COALESCE(config, '{}'::jsonb), ARRAY[?], ?::jsonb, true)",
          CONFIG_KEY, document.to_json
        ]).positive?
      end
    end
  end
end
