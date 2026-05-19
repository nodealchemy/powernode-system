# frozen_string_literal: true

require "yaml"

module System
  module Gitops
    # Parses the `fleet.yaml` (or other path_prefix-located YAML) inside a
    # GitOps work tree into a structured DesiredState. Handles top-level
    # keys: `templates`, `assignments`, `modules`, `provider_configs`.
    #
    # Schema is intentionally simple — every section is a map of name →
    # attributes. Reconcilers consume this object directly.
    #
    # Reference: comprehensive stabilization sweep P5.
    class DesiredStateParser
      Result = Struct.new(:ok?, :desired_state, :error, keyword_init: true)

      DesiredState = Struct.new(:templates, :assignments, :modules, :provider_configs, keyword_init: true) do
        def empty?
          templates.empty? && assignments.empty? && modules.empty? && provider_configs.empty?
        end
      end

      DEFAULT_FILENAME = "fleet.yaml"
      MAX_FILE_SIZE = 1.megabyte

      def self.parse!(work_tree_path:, path_prefix: "", filename: DEFAULT_FILENAME)
        new(work_tree_path: work_tree_path, path_prefix: path_prefix, filename: filename).parse!
      end

      def initialize(work_tree_path:, path_prefix: "", filename: DEFAULT_FILENAME)
        @work_tree_path = work_tree_path
        @path_prefix = path_prefix.to_s.strip.delete_prefix("/").delete_suffix("/")
        @filename = filename
      end

      def parse!
        path = full_path
        return Result.new(ok?: false, error: "fleet.yaml not found at #{path}") unless File.exist?(path)
        return Result.new(ok?: false, error: "fleet.yaml exceeds #{MAX_FILE_SIZE} bytes") if File.size(path) > MAX_FILE_SIZE

        raw = YAML.safe_load(
          File.read(path),
          permitted_classes: [ Symbol, Date, Time ],
          aliases: true
        )

        raw = {} if raw.nil?
        return Result.new(ok?: false, error: "fleet.yaml must be a YAML mapping (Hash)") unless raw.is_a?(Hash)

        # P2.6 schema gate — catches authoring bugs (typos, bad enums, wrong
        # types) at parse time so the reconciler surfaces structured errors
        # rather than ActiveRecord::RecordInvalid at apply time.
        validation = DesiredStateValidator.call(raw)
        unless validation.ok?
          return Result.new(ok?: false, error: "fleet.yaml schema errors — #{validation.error_summary}")
        end

        Result.new(
          ok?: true,
          desired_state: DesiredState.new(
            templates: parse_section(raw["templates"]),
            assignments: parse_section(raw["assignments"]),
            modules: parse_section(raw["modules"]),
            provider_configs: parse_section(raw["provider_configs"])
          )
        )
      rescue Psych::SyntaxError => e
        Result.new(ok?: false, error: "YAML syntax error: #{e.message}")
      rescue StandardError => e
        Result.new(ok?: false, error: "#{e.class}: #{e.message}")
      end

      private

      def full_path
        if @path_prefix.present?
          File.join(@work_tree_path, @path_prefix, @filename)
        else
          File.join(@work_tree_path, @filename)
        end
      end

      def parse_section(section)
        return {} if section.nil?
        return section if section.is_a?(Hash)
        return Hash[section.map { |item| [ item["name"] || item[:name], item ] }] if section.is_a?(Array)
        {}
      end
    end
  end
end
