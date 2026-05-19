# frozen_string_literal: true

module System
  module Gitops
    # Schema validator for fleet.yaml's top-level + per-section shape.
    #
    # Catches authoring bugs at parse time instead of at ActiveRecord-save
    # time, so the GitOps reconciler can surface structured per-field errors
    # ("templates.foo.node_platform: must be a string slug") rather than the
    # cryptic ActiveRecord::RecordInvalid messages reconcilers used to spit.
    #
    # Audit plan item: P2.6.
    #
    # NOTE: Implemented as plain Ruby rather than dry-validation because
    # parent platform's Gemfile doesn't currently include dry-validation,
    # and pulling it in for one validator isn't worth the cross-repo
    # coordination. Per-rule structure mirrors what dry-validation would
    # produce — easy migration target if dry-validation lands later for
    # other reasons.
    class DesiredStateValidator
      Result = Struct.new(:ok?, :errors, keyword_init: true) do
        # errors is { "json.pointer.path" => ["message", ...], ... }
        def error_summary
          return nil if ok?

          errors.flat_map { |path, msgs| msgs.map { |m| "#{path}: #{m}" } }.join("; ")
        end
      end

      MODULE_VARIETIES = %w[subscription role config instance].freeze
      TEMPLATE_STRING_KEYS = %w[description node_platform provider_region instance_type].freeze
      ASSIGNMENT_BOOLEAN_KEYS = %w[enabled].freeze

      def self.call(raw)
        new(raw).call
      end

      def initialize(raw)
        @raw = raw.is_a?(Hash) ? raw : {}
        @errors = Hash.new { |h, k| h[k] = [] }
      end

      def call
        validate_top_level
        validate_templates
        validate_assignments
        validate_modules
        validate_fleet_block

        if @errors.empty?
          Result.new(ok?: true, errors: {})
        else
          Result.new(ok?: false, errors: @errors)
        end
      end

      private

      ALLOWED_TOP_LEVEL = %w[templates assignments modules provider_configs fleet].freeze

      def validate_top_level
        @raw.each_key do |k|
          next if ALLOWED_TOP_LEVEL.include?(k.to_s)

          @errors[k.to_s] << "unknown top-level key (allowed: #{ALLOWED_TOP_LEVEL.join(', ')})"
        end
      end

      def validate_templates
        templates = @raw["templates"]
        return if templates.nil?
        unless templates.is_a?(Hash)
          @errors["templates"] << "must be a mapping of name → attributes"
          return
        end

        templates.each do |name, attrs|
          path = "templates.#{name}"
          unless attrs.is_a?(Hash)
            @errors[path] << "must be a hash"
            next
          end

          TEMPLATE_STRING_KEYS.each do |k|
            next unless attrs.key?(k)
            unless attrs[k].is_a?(String)
              @errors["#{path}.#{k}"] << "must be a string (got #{attrs[k].class})"
            end
          end
        end
      end

      def validate_assignments
        assignments = @raw["assignments"]
        return if assignments.nil?
        unless assignments.is_a?(Hash)
          @errors["assignments"] << "must be a mapping of 'node-name:module-name' → attributes"
          return
        end

        assignments.each do |key, attrs|
          path = "assignments.#{key}"
          unless key.is_a?(String) && key.include?(":")
            @errors[path] << "key must be in 'node-name:module-name' format"
          end
          next unless attrs.is_a?(Hash)

          ASSIGNMENT_BOOLEAN_KEYS.each do |k|
            next unless attrs.key?(k)
            unless [true, false].include?(attrs[k])
              @errors["#{path}.#{k}"] << "must be true or false"
            end
          end
        end
      end

      def validate_modules
        modules = @raw["modules"]
        return if modules.nil?
        unless modules.is_a?(Hash)
          @errors["modules"] << "must be a mapping of name → attributes"
          return
        end

        modules.each do |name, attrs|
          path = "modules.#{name}"
          unless attrs.is_a?(Hash)
            @errors[path] << "must be a hash"
            next
          end

          if attrs.key?("variety") && !MODULE_VARIETIES.include?(attrs["variety"].to_s)
            @errors["#{path}.variety"] << "must be one of #{MODULE_VARIETIES.join('|')}"
          end
          if attrs.key?("priority") && !attrs["priority"].is_a?(Integer)
            @errors["#{path}.priority"] << "must be an integer (got #{attrs['priority'].class})"
          end
        end
      end

      ALLOWED_FLEET_KEYS = %w[default_template provider].freeze

      def validate_fleet_block
        fleet = @raw["fleet"]
        return if fleet.nil?
        unless fleet.is_a?(Hash)
          @errors["fleet"] << "must be a hash"
          return
        end

        fleet.each_key do |k|
          next if ALLOWED_FLEET_KEYS.include?(k.to_s)

          @errors["fleet.#{k}"] << "unknown key (allowed: #{ALLOWED_FLEET_KEYS.join(', ')})"
        end
        ALLOWED_FLEET_KEYS.each do |k|
          next unless fleet.key?(k)
          unless fleet[k].is_a?(String)
            @errors["fleet.#{k}"] << "must be a string"
          end
        end
      end
    end
  end
end
