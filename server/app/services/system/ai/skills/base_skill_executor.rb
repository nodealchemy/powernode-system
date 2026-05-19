# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Common base class for every system-extension skill executor.
      #
      # Owns the shared lifecycle that previously duplicated across 40 files:
      #   - `initialize(account:, agent:, user:)` signature
      #   - descriptor declaration via DSL (`skill_descriptor`)
      #   - agent binding declaration via DSL (`binds_to`)
      #   - `execute` orchestration: validate → audit log → perform → audit log
      #   - `success` / `failure` result builders
      #   - tool construction via `tool(::Ai::Tools::FooTool)`
      #
      # Subclasses define:
      #   - `skill_descriptor(...)` at class scope (required)
      #   - `binds_to "Agent Name", ...` at class scope (required for runtime use)
      #   - `def perform(**) ...` instance method (required) — gets keyword args
      #     forwarded from `execute`. May call `success(...)` / `failure(...)`,
      #     `tool(...)`, and read `@account`, `@agent`, `@user`.
      #
      # Example:
      #
      #   class FooExecutor < BaseSkillExecutor
      #     skill_descriptor(
      #       name: "foo", description: "...", category: "fleet",
      #       inputs:  { id: { type: "string", required: true } },
      #       outputs: { foo_id: :string }
      #     )
      #     binds_to "Fleet Autonomy"
      #
      #     protected
      #
      #     def perform(id:)
      #       result = tool(::Ai::Tools::FooTool).execute(params: { action: "foo_get", id: id })
      #       result[:success] ? success(result[:data]) : failure(result[:error])
      #     end
      #   end
      class BaseSkillExecutor
        class << self
          # Declare the executor's descriptor at class scope. The hash gets
          # frozen + memoized; subclasses can read it via `.descriptor`.
          #
          # `name` is the short skill identifier (e.g. "cve_response"); the
          # canonical slug derived by `SkillBindings.discover` is
          # "system-#{class_name.demodulize.underscore.sub(/_executor$/, '').dasherize}".
          def skill_descriptor(name:, description:, category:, inputs:, outputs:,
                               requires_approval: false, invocation_mode: "one_shot",
                               domain: "system", tags: [], **extras)
            # `**extras` lets executors declare descriptor keys this DSL
            # doesn't model explicitly (e.g. `rollback: :method_name`,
            # `blast_radius: :low|:medium|:high`, future per-domain metadata).
            # Keys captured here flow into the frozen descriptor verbatim.
            @descriptor = {
              name: name,
              description: description,
              category: category,
              inputs: inputs,
              outputs: outputs,
              requires_approval: requires_approval,
              invocation_mode: invocation_mode,
              domain: domain,
              tags: tags,
              **extras
            }.freeze
          end

          # Returns the frozen descriptor hash. Raises if `skill_descriptor`
          # wasn't called — surfaces the bug at first reference instead of
          # returning nil downstream.
          def descriptor
            @descriptor or raise NotImplementedError,
                                "#{name} must call `skill_descriptor(...)` at class scope"
          end

          # Register this executor with SkillBindings for the named agents.
          # Replaces the trailing `SkillBindings.register(self, agents: [...])`
          # call that lived at the bottom of each executor file.
          #
          # Accepts agent names or aliases (see SkillBindings::AGENT_ALIASES).
          def binds_to(*agents)
            SkillBindings.register(self, agents: agents)
          end
        end

        attr_reader :account, :agent, :user

        def initialize(account:, agent: nil, user: nil)
          raise ArgumentError, "account is required" if account.nil?

          @account = account
          @agent   = agent
          @user    = user
        end

        # Public entry point. Validates required inputs against the descriptor,
        # audit-logs start, dispatches to subclass `#perform`, audit-logs
        # finish, and wraps any uncaught exception in a `failure(...)` result.
        def execute(**inputs)
          validate_inputs!(inputs)
          audit_log_start(inputs)
          result = perform(**inputs)
          audit_log_finish(result)
          result
        rescue StandardError, NotImplementedError => e
          # Catch NotImplementedError too — abstract subclasses that forgot
          # to override #perform should flow through the same failure
          # pipeline as any other error, not crash the caller.
          audit_log_error(e)
          failure(e.message)
        end

        protected

        # Subclasses MUST override. Receives the same keyword args that were
        # passed to `execute`. Should return `success(payload)` or
        # `failure(message)`.
        def perform(**)
          raise NotImplementedError, "#{self.class.name}#perform must be defined"
        end

        # Default required-input validation: any descriptor input with
        # `required: true` must be present (non-nil) in `inputs`. Subclasses
        # can override for richer validation (type checks, enum membership, etc).
        def validate_inputs!(inputs)
          declared = self.class.descriptor[:inputs] || {}
          declared.each do |key, spec|
            next unless spec.is_a?(Hash) && spec[:required]
            raise ArgumentError, "missing required input: #{key}" if inputs[key].nil?
          end
        end

        def success(payload)
          { success: true, data: payload }
        end

        def failure(msg)
          { success: false, error: msg }
        end

        # Standardized tool construction. Replaces the 40 sites that built
        # `::Ai::Tools::SomeTool.new(account: @account, agent: @agent, user: @user)`
        # inline. Pass the tool class; the helper handles the 3-arg constructor.
        def tool(tool_class)
          tool_class.new(account: @account, agent: @agent, user: @user)
        end

        def audit_log_start(inputs)
          Rails.logger.tagged(self.class.name) do
            Rails.logger.info("execute_start agent=#{@agent&.id} input_keys=#{inputs.keys.inspect}")
          end
        end

        def audit_log_finish(result)
          Rails.logger.tagged(self.class.name) do
            Rails.logger.info("execute_finish success=#{result[:success]}")
          end
        end

        def audit_log_error(exc)
          Rails.logger.tagged(self.class.name) do
            Rails.logger.error("execute_error #{exc.class}: #{exc.message}")
          end
        end
      end
    end
  end
end
