# frozen_string_literal: true

module System
  module Gitops
    # Compares parsed DesiredState to live database state. Returns an array
    # of Diff objects, each describing one resource that needs to be
    # created, updated, or destroyed.
    #
    # Coverage: templates (NodeTemplate), assignments (NodeModuleAssignment),
    # modules (NodeModule). Provider configs are flagged but not diffed
    # (operator-only state).
    #
    # Reference: comprehensive stabilization sweep P5.
    class DiffEngine
      Diff = Struct.new(:kind, :resource_id, :name, :change, :current, :desired, keyword_init: true) do
        def to_h
          { kind: kind, resource_id: resource_id, name: name, change: change,
            current: current, desired: desired }
        end
      end

      Result = Struct.new(:ok?, :diffs, :error, keyword_init: true)

      def self.diff!(account:, desired_state:)
        new(account: account, desired_state: desired_state).diff!
      end

      def initialize(account:, desired_state:)
        @account = account
        @desired_state = desired_state
      end

      def diff!
        diffs = []
        diffs.concat(diff_templates)
        diffs.concat(diff_assignments)
        diffs.concat(diff_modules)
        diffs.concat(diff_provider_configs)
        Result.new(ok?: true, diffs: diffs)
      rescue StandardError => e
        Rails.logger.error("[Gitops::DiffEngine] #{e.class}: #{e.message}")
        Result.new(ok?: false, error: e.message, diffs: [])
      end

      private

      def diff_templates
        compare_collection(
          kind: "template",
          desired: @desired_state.templates,
          live_scope: ::System::NodeTemplate.where(account: @account),
          identity_proc: ->(record) { record.name },
          state_proc: ->(record) { record.attributes.slice("name", "description", "node_platform_id") }
        )
      end

      def diff_modules
        compare_collection(
          kind: "module",
          desired: @desired_state.modules,
          live_scope: ::System::NodeModule.where(account: @account),
          identity_proc: ->(record) { record.name },
          state_proc: ->(record) { record.attributes.slice("name", "priority", "variety", "config") }
        )
      end

      def diff_assignments
        # Assignments are scoped per-(node, module) pair. The desired-state
        # entry is `name = "<node-name>:<module-name>"` for human readability.
        live = ::System::NodeModuleAssignment
          .joins(:node, :node_module)
          .where(system_nodes: { account_id: @account.id })
          .map do |a|
            key = "#{a.node.name}:#{a.node_module.name}"
            [ key, a.attributes.slice("enabled", "priority", "config") ]
          end.to_h

        diffs = []
        @desired_state.assignments.each do |key, desired_attrs|
          if live.key?(key)
            if live[key] != normalize_attrs(desired_attrs)
              diffs << Diff.new(kind: "assignment", resource_id: nil, name: key,
                                change: :update, current: live[key], desired: desired_attrs)
            end
          else
            diffs << Diff.new(kind: "assignment", resource_id: nil, name: key,
                              change: :create, current: nil, desired: desired_attrs)
          end
        end

        # Live assignments not in desired-state are flagged as :destroy candidates.
        # NOTE: GitOps mode does NOT auto-destroy by default — destroyability is
        # an operator-approved proposal kind.
        live.each_key do |key|
          next if @desired_state.assignments.key?(key)
          diffs << Diff.new(kind: "assignment", resource_id: nil, name: key,
                            change: :destroy, current: live[key], desired: nil)
        end

        diffs
      end

      def diff_provider_configs
        # Provider configs (provider_connections) are credentials — never
        # rotated via GitOps. Surface as informational diff only.
        @desired_state.provider_configs.keys.map do |name|
          Diff.new(kind: "provider_config", resource_id: nil, name: name,
                   change: :informational, current: nil, desired: { note: "managed via UI; GitOps does not rotate credentials" })
        end
      end

      def compare_collection(kind:, desired:, live_scope:, identity_proc:, state_proc:)
        diffs = []
        live_by_name = live_scope.index_by { |r| identity_proc.call(r) }

        desired.each do |name, desired_attrs|
          live = live_by_name[name]
          if live
            current = state_proc.call(live)
            normalized_desired = normalize_attrs(desired_attrs)
            if current != normalized_desired.slice(*current.keys)
              diffs << Diff.new(kind: kind, resource_id: live.id, name: name,
                                change: :update, current: current, desired: desired_attrs)
            end
          else
            diffs << Diff.new(kind: kind, resource_id: nil, name: name,
                              change: :create, current: nil, desired: desired_attrs)
          end
        end

        live_by_name.each do |name, live|
          next if desired.key?(name)
          diffs << Diff.new(kind: kind, resource_id: live.id, name: name,
                            change: :destroy, current: state_proc.call(live), desired: nil)
        end

        diffs
      end

      def normalize_attrs(attrs)
        return {} unless attrs.is_a?(Hash)
        attrs.transform_keys(&:to_s)
      end
    end
  end
end
