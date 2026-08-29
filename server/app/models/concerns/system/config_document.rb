# frozen_string_literal: true

module System
  # ONE way to write a key into System::NodeInstance#config.
  #
  # == THE HAZARD
  #
  # `config` is a SHARED jsonb document. It is written from mutually unaware
  # request cycles: the operator API, the MCP fleet tools, half a dozen
  # background services, and — several times a minute per node — the agent
  # telemetry lanes (System::BootLkgStateWriter, System::ModuleVerifyStateWriter,
  # System::RuntimeMetricsWriter, Sdwan::AgentApplyStateWriter).
  #
  # A read-modify-write of the WHOLE document —
  #
  #     instance.update!(config: (instance.config || {}).merge("k" => v))
  #     instance.update_columns(config: cfg)
  #     instance.config["k"] = v; instance.save!
  #
  # — serializes the document as it looked when THIS object was loaded. Anything
  # another writer stored in the interval is erased. The interval is not
  # theoretical: an operator action that loads an instance, calls a provider,
  # and then stamps a marker holds a stale document across a network round trip,
  # while the node it is acting on heartbeats every ~30s into the same column.
  # The lost write is silent on both sides — no exception, no conflict, just a
  # telemetry document that reverts to an older version and a sensor that reads
  # the stale answer as current.
  #
  # == THE SHAPE THAT IS SAFE
  #
  # Let Postgres do the merge against the CURRENT row. `||` is a shallow merge:
  # only the top-level keys in the argument are replaced, and the statement
  # never reads the rest of the document into Ruby, so there is no interval to
  # lose a write in. The four telemetry writers above already do exactly this
  # (their private #merge_config_key!); this concern is that idiom promoted to
  # the model so every other writer can reach it, and so the guard spec
  # (spec/lint/node_instance_config_write_seam_spec.rb) has one adoption target
  # to check against.
  #
  # == WHAT THIS DOES NOT DO
  #
  # It does not make concurrent writes to the SAME key safe — two writers of
  # `config["storage_volume"]` still last-write-wins, which is the intended
  # semantics for a key with a single owner. It bounds the damage to the keys
  # the caller actually names. Nested merges are NOT performed: passing
  # `{"netboot" => {...}}` replaces the whole `netboot` subtree, so a caller
  # that owns only part of a subtree must still compose that subtree itself
  # (and accepts last-write-wins within it).
  #
  # == IN-MEMORY CONSISTENCY
  #
  # Because the write happens in SQL, `self.config` would otherwise still hold
  # the pre-merge document — and a later `save!` on the same object would write
  # that stale value straight back, re-introducing the clobber one line further
  # down. So both writers re-read the column and clear its dirty state. That
  # costs one extra SELECT per write, which these operator/service paths can
  # afford; the per-tick telemetry writers deliberately do not pay it and keep
  # their own class-level statements.
  module ConfigDocument
    extend ActiveSupport::Concern

    class_methods do
      # Shallow-merges `document`'s top-level keys into the row's config.
      # Returns whether a row was written.
      def merge_config_document!(id:, document:, touch: true)
        document = normalize_config_document(document)
        return false if document.empty?

        sql   = +"config = COALESCE(config, '{}'::jsonb) || ?::jsonb"
        binds = [ document.to_json ]
        if touch
          sql << ", updated_at = ?"
          binds << Time.current
        end

        where(id: id).update_all([ sql, *binds ]).positive?
      end

      # Removes `keys` from the row's config. The jsonb `-` operator, like `||`,
      # never reads the rest of the document. Returns whether a row was written.
      def delete_config_document_keys!(id:, keys:, touch: true)
        keys = Array(keys).map(&:to_s).reject(&:empty?).uniq
        return false if keys.empty?

        sql   = +"config = COALESCE(config, '{}'::jsonb) - ARRAY[?]::text[]"
        binds = [ keys ]
        if touch
          sql << ", updated_at = ?"
          binds << Time.current
        end

        where(id: id).update_all([ sql, *binds ]).positive?
      end

      # String keys, always: the column round-trips as strings, and a
      # symbol-keyed document would merge as a SECOND key alongside the string
      # one already stored — a duplicate that reads as the key being set while
      # every consumer keeps seeing the old value.
      def normalize_config_document(document)
        return {} if document.nil?
        raise ArgumentError, "config document must be a Hash" unless document.respond_to?(:to_h)

        document.to_h.transform_keys(&:to_s)
      end
    end

    # Replaces the named top-level keys and leaves every other key alone.
    #
    # Both call shapes work — `merge_config!("k" => v)` and
    # `merge_config!({ "k" => v }, touch: false)` — because Ruby routes a bare
    # `k => v` list to keywords whenever the method declares any, and a seam
    # whose most natural call raises ArgumentError is a seam people route
    # around. The one ambiguity: a config key literally named `touch` must be
    # passed inside an explicit hash, or it is read as the option.
    def merge_config!(document = nil, touch: true, **keys)
      document = self.class.normalize_config_document(document).merge(
        self.class.normalize_config_document(keys)
      )
      written = self.class.merge_config_document!(id: id, document: document, touch: touch)
      reload_config_attribute! if written
      written
    end

    # Removes the named top-level keys and leaves every other key alone.
    def delete_config_keys!(*keys, touch: true)
      written = self.class.delete_config_document_keys!(id: id, keys: keys.flatten, touch: touch)
      reload_config_attribute! if written
      written
    end

    private

    # Re-reads ONLY `config`, then clears its dirty state so a subsequent
    # `save!` on this object does not write the document back wholesale. A full
    # `reload` would also discard unsaved changes to other attributes, which
    # callers that merge config mid-transaction do not expect.
    def reload_config_attribute!
      self.config = self.class.where(id: id).pick(:config)
      clear_attribute_changes([ :config ])
      config
    end
  end
end
