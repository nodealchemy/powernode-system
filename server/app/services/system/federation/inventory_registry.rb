# frozen_string_literal: true

module System
  module Federation
    # Loads `federation_inventory.yaml` from each enabled extension at
    # boot. Aggregates the declared `exportable_kinds` into a queryable
    # registry used by:
    #
    #   - federation_api/capabilities (validate caller's requested kinds)
    #   - Migration::PlanComposer (resolve dependency manifests per kind)
    #   - Acceptance-flow validation (refuse capabilities for unknown kinds)
    #
    # Inventory schema (per `docs/federation/MODULE_MANIFEST_SCHEMA.md`'s
    # sibling at `extensions/<slug>/federation_inventory.yaml`):
    #
    #   extension: trading
    #   exportable_kinds:
    #     - kind: skill
    #       dependencies: [learning, knowledge_base_entry]
    #       duplicable: true
    #       migratable: false
    #     - kind: trading_strategy
    #       dependencies: [skill]
    #       duplicable: true
    #       migratable: true
    #
    # (The `logical_clock_column` field was withdrawn per Locked
    #  Decision #14 — there is no cross-peer "which version wins"
    #  question under the single-home-per-UUID rule.)
    #
    # Plan reference: Decentralized Federation §D + P4.5 + LD #14.
    class InventoryRegistry
      class LoadError < StandardError; end

      # An immutable record describing one exportable resource kind.
      Kind = Struct.new(
        :extension, :kind, :dependencies, :duplicable, :migratable,
        :metadata,
        keyword_init: true
      )

      class << self
        # Returns the singleton instance. Loads on first call; subsequent
        # calls return the cached registry. Call `reload!` to force re-read.
        def instance
          @instance ||= load!
        end

        def reload!
          @instance = load!
        end

        # Convenience accessors that delegate to the singleton.
        def all_kinds
          instance.all_kinds
        end

        def find_kind(kind_name)
          instance.find_kind(kind_name)
        end

        def for_extension(extension_slug)
          instance.for_extension(extension_slug)
        end

        def kind_known?(kind_name)
          instance.kind_known?(kind_name)
        end

        # Test hook: install a registry built from in-memory data without
        # touching the filesystem. Pass nil to revert to disk-loaded mode.
        def install_test_double(registry)
          @instance = registry
        end

        # Returns the path the loader will walk. Test override-able.
        def extensions_root
          @extensions_root ||= Rails.root.join("..", "..").to_s
        end

        attr_writer :extensions_root

        private

        def load!
          new.tap(&:load_from_disk!)
        end
      end

      def initialize
        @kinds_by_name = {}
        @kinds_by_extension = Hash.new { |h, k| h[k] = [] }
      end

      def load_from_disk!
        root = self.class.extensions_root
        ext_dir = File.join(root, "extensions")
        return self unless Dir.exist?(ext_dir)

        Dir.children(ext_dir).sort.each do |slug|
          next if extension_disabled?(slug)

          path = File.join(ext_dir, slug, "federation_inventory.yaml")
          next unless File.exist?(path)

          parse_inventory(slug, path)
        end
        self
      end

      def all_kinds
        @kinds_by_name.values
      end

      def find_kind(kind_name)
        @kinds_by_name[kind_name.to_s]
      end

      def for_extension(extension_slug)
        @kinds_by_extension[extension_slug.to_s]
      end

      def kind_known?(kind_name)
        @kinds_by_name.key?(kind_name.to_s)
      end

      # Test seam: register a kind without going through disk parsing.
      def register_kind(kind_attrs)
        record = kind_attrs.is_a?(Kind) ? kind_attrs : Kind.new(**kind_attrs)
        @kinds_by_name[record.kind.to_s] = record
        @kinds_by_extension[record.extension.to_s] << record
        record
      end

      private

      def parse_inventory(slug, path)
        data = YAML.safe_load(File.read(path), permitted_classes: [ Symbol ])
        unless data.is_a?(Hash)
          raise LoadError, "federation_inventory.yaml for #{slug.inspect} is not a hash"
        end

        ext_name = (data["extension"] || slug).to_s
        Array(data["exportable_kinds"]).each do |entry|
          next unless entry.is_a?(Hash) && entry["kind"].is_a?(String)

          record = Kind.new(
            extension: ext_name,
            kind: entry["kind"],
            dependencies: Array(entry["dependencies"]).map(&:to_s),
            duplicable: entry.fetch("duplicable", true),
            migratable: entry.fetch("migratable", false),
            metadata: entry["metadata"].is_a?(Hash) ? entry["metadata"] : {}
          )
          @kinds_by_name[record.kind] = record
          @kinds_by_extension[record.extension] << record
        end
      end

      def extension_disabled?(slug)
        state_path = File.join(self.class.extensions_root, "config", "extensions_state.json")
        return false unless File.exist?(state_path)

        state = JSON.parse(File.read(state_path))
        Array(state["disabled"]).map(&:to_s).include?(slug)
      rescue JSON::ParserError, IOError, SystemCallError
        false
      end
    end
  end
end
