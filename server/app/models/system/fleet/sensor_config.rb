# frozen_string_literal: true

module System
  module Fleet
    # IMP-ca485128072e (APO-2e) — the operator's tuning surface for fleet sensor
    # thresholds, and the row docs/FLEET_SENSORS.md has named since the sensor
    # section was written.
    #
    # ONE ROW PER [account, sensor], holding ONLY the keys an operator has
    # actually overridden. That sparseness is deliberate: a sensor's constant is
    # the platform's current best answer, and an account that never tuned a key
    # should move with it when it changes. A row that snapshotted every default
    # at write time would freeze the untouched keys too, which is how a "config
    # table" quietly becomes a fork of the code.
    #
    # NOT the resolver. Reading happens through
    # System::Fleet::Sensors::BaseSensor.resolved_threshold, which merges this
    # over the class constants, validates, and falls back — so a sensor tick
    # never sees a raw stored value. Nothing else should read #config directly.
    class SensorConfig < BaseRecord
      self.table_name = "system_fleet_sensor_configs"

      belongs_to :account

      validates :sensor, presence: true,
                         uniqueness: { scope: :account_id, case_sensitive: true }

      attribute :config, :jsonb, default: -> { {} }

      # The stored overrides for one sensor, always a plain string-keyed Hash.
      # Returns {} for an account that has never tuned this sensor — the caller
      # cannot distinguish "no row" from "row with no overrides", and must not:
      # both mean "every key resolves to its constant".
      def self.config_for(account:, sensor:)
        row = find_by(account_id: account.id, sensor: sensor.to_s)
        raw = row&.config
        raw.is_a?(Hash) ? raw.deep_stringify_keys : {}
      end

      # THE ONE definition of "a usable threshold value", read by both the
      # resolver (BaseSensor.resolved_threshold, which falls back when this
      # returns nil) and the MCP write verb (which refuses to STORE what the
      # resolver would silently ignore). Two copies of this rule would let the
      # writer accept a value the reader then discards — a success with no
      # effect, which is the exact failure this whole seam replaces.
      #
      # Deliberately strict about the STRING case: "600" out of a JSON body is
      # a number an operator meant, while "not-a-number".to_i is 0 and would
      # read as a deliberate zero. Non-positive is never usable — `max_per_tick`
      # of 0 disables a detector while looking like configuration.
      #
      # A Float must be INTEGRAL as well as positive. `600.0` is how a JSON
      # body can spell 600 and is accepted; `0.5` and `1.5` are not. Testing
      # only `.positive?` and then calling `.to_i` was a hole in exactly the
      # rule above: `0.5.positive?` is true and `0.5.to_i` is 0, so the writer
      # accepted a value the resolver then used AS ZERO — `.limit(0)` on
      # instance_unrecoverable (a detector silently stopped) and a
      # `Time.current` cutoff on instance_status (every instance reported
      # silent). 0 is truthy in Ruby, so `coerce_threshold(x) || fallback`
      # would not have fallen back either. `1.5` is refused rather than
      # truncated: storing 1 for an operator who asked for 1.5 is a quieter
      # version of the same lie.
      def self.coerce_threshold(value)
        case value
        when Integer then value.positive? ? value : nil
        when Float then value.finite? && value == value.truncate && value.truncate.positive? ? value.truncate : nil
        when String then value.match?(/\A\d+\z/) && value.to_i.positive? ? value.to_i : nil
        end
      end

      # MERGE, not replace. A partial update names the keys it is changing; the
      # ones it omits keep whatever the operator set before. Replacing would
      # make every write a full re-statement of the sensor's config, and a
      # single-key MCP call would silently drop the rest.
      #
      # Deleting an override is `config: { key => nil }` — see #merge_overrides.
      #
      # Read-modify-write, so it takes the ROW LOCK for the merge: two
      # concurrent single-key writes to the same sensor would otherwise both
      # read the pre-write config and the second would drop the first
      # operator's key. The unique index makes the row count safe; it does
      # nothing about a lost update. When the row does not exist yet the index
      # is what arbitrates, and the loser retries into the branch that locks.
      def self.upsert_for(account:, sensor:, config:)
        attempted_insert_race = false
        begin
          transaction do
            row = lock.find_by(account_id: account.id, sensor: sensor.to_s) ||
                  new(account_id: account.id, sensor: sensor.to_s, config: {})
            row.config = merge_overrides(row.config, config)
            row.save!
            row
          end
        rescue ActiveRecord::RecordNotUnique
          raise if attempted_insert_race

          attempted_insert_race = true
          retry
        end
      end

      # An explicit nil REMOVES the override rather than storing a null the
      # resolver would then have to treat as absent. Without this there is no
      # way back to the constant short of deleting the row, which would also
      # drop every other key on it.
      def self.merge_overrides(existing, incoming)
        base = existing.is_a?(Hash) ? existing.deep_stringify_keys : {}
        (incoming || {}).each do |key, value|
          if value.nil?
            base.delete(key.to_s)
          else
            base[key.to_s] = value
          end
        end
        base
      end
      private_class_method :merge_overrides
    end
  end
end
