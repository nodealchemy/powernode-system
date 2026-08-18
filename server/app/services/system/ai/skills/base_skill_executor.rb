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

        # The MCP INSTANCE provenance, injected post-construction by whatever
        # routed here — SdwanTool#run_skill_executor and SystemIngressTool
        # #run_executor set it; a reconciler leaves it alone. Both forwarded
        # only `user:`, and an instance principal (mTLS node cert) has no User,
        # so at `#tool` below it was indistinguishable from an autonomy
        # reconciler and inherited the reconciler's in-process bypass for every
        # tool the executor nests. (IMP-0e6b216de843)
        #
        # Writers rather than constructor keywords, mirroring the same pair on
        # Ai::Tools::BaseTool (set by McpPlatformToolRegistrar): every call site
        # guards on the instance case, so `.new` and the reconciler/user paths
        # stay byte-for-byte unchanged across all 54 executors.
        attr_writer :instance_authorized
        attr_accessor :node_instance

        def initialize(account:, agent: nil, user: nil)
          raise ArgumentError, "account is required" if account.nil?

          @account = account
          @agent   = agent
          @user    = user
          @instance_authorized = false
          @node_instance = nil
        end

        # Public entry point. Validates required inputs against the descriptor,
        # audit-logs start, dispatches to subclass `#perform`, audit-logs
        # finish, and wraps any uncaught exception in a `failure(...)` result.
        def execute(**inputs)
          validate_inputs!(inputs)
          audit_log_start(inputs)
          result = perform(**acceptable_inputs(inputs))
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

        # Subclasses MUST override. Receives the keyword args passed to
        # `execute`, sliced to the keywords the override declares (see
        # #acceptable_inputs). Should return `success(payload)` or
        # `failure(message)`.
        def perform(**)
          raise NotImplementedError, "#{self.class.name}#perform must be defined"
        end

        # A composed plan hands every step a SUPERSET of inputs — notably the
        # shared `brief` the composer stamps onto each step — while executors
        # declare strict keyword signatures. Live (dryrun 20260809c), every
        # docker_provision step failed `ArgumentError: unknown keyword:
        # :brief` before #perform ever ran. Slice the inputs to the keywords
        # the override declares; a `**rest` capture is the executor's
        # explicit opt-in to receiving everything. Required-input validation
        # has already run against the FULL input set by this point, so
        # slicing can only drop extras, never mask a missing declared input.
        def acceptable_inputs(inputs)
          params = method(:perform).parameters
          return inputs if params.any? { |type, _| type == :keyrest }

          keys = params.filter_map { |type, name| name if %i[key keyreq].include?(type) }
          inputs.slice(*keys)
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

        # IMP-2182fd8fcdee — `**extra` is what makes the runner's failure-time
        # rollback seam reachable at all. SkillCompositionRunner#handle_failure
        # calls record_failure_outputs BEFORE mark_failed, and its
        # failure_outputs_from strips the envelope control keys (success, error,
        # message, errors, failures, partial) off whatever the executor
        # returned. So a resource-creating executor that fails AFTER creating
        # can name its orphans right here and rollback_step! will receive them
        # as kwargs. A bare failure(msg) leaves that payload empty, the rollback
        # no-ops, and mark_rolled_back then stamps `rolled_back` over resources
        # that are still live and billing.
        #
        # Pass ONLY keys that actually hold ids: an outputs hash that is
        # "present" while empty displaces a retried step's genuine last_outputs
        # and fakes compensation in one move.
        def failure(msg, **extra)
          { success: false, error: msg }.merge(extra)
        end

        # True when this executor is running on behalf of a grant-gated MCP
        # instance principal rather than an in-process caller.
        def instance_authorized?
          @instance_authorized == true
        end

        # A userless executor is a trusted in-process system caller — autonomy
        # reconcilers build executors with `user: nil` (System::Fleet::
        # DecisionEngine) and mean exactly that — UNLESS it is serving an
        # instance principal, which arrives with no user either. Only that
        # second case was invisible here, which is why `@user.nil?` alone was
        # the wrong test. (IMP-0e6b216de843)
        def internal_caller?
          @user.nil? && !instance_authorized?
        end

        # Standardized tool construction. Replaces the 40 sites that built
        # `::Ai::Tools::SomeTool.new(account: @account, agent: @agent, user: @user)`
        # inline. Pass the tool class; the helper handles the constructor.
        #
        # This is the single funnel for every executor-nested tool, so it is
        # where the caller's identity has to be told truthfully:
        #
        #   reconciler  -> `internal: true`, the documented in-process bypass.
        #   instance    -> NOT internal; marked `instance_authorized` instead.
        #
        # The mark is provenance, not a wider bypass — it is what re-arms
        # Mcp::Principal's destructive deny overlay against the action this
        # nested tool is about to run (Ai::Tools::BaseTool#execute). Under the
        # old `internal: @user.nil?` an instance got the reconciler's bypass and
        # the nested tool name was never checked against the overlay at all.
        # (IMP-9030413bc292 closed the first hop; IMP-0e6b216de843 this one.)
        def tool(tool_class)
          built = tool_class.new(account: @account, agent: @agent, user: @user,
                                 internal: internal_caller?)
          mark_instance_provenance(built)
        end

        # Build a peer/child executor carrying THIS executor's caller context.
        # Composers that nest other executors must not drop the instance
        # provenance one hop further down — that re-creates the same bypass
        # inside the child. (IMP-0e6b216de843)
        def executor(executor_class, **overrides)
          mark_instance_provenance(
            executor_class.new(account: @account, agent: @agent, user: @user, **overrides)
          )
        end

        # Guarded: touches nothing unless this executor is itself serving an
        # instance principal, so reconciler and user calls are unchanged.
        def mark_instance_provenance(target)
          return target unless instance_authorized?

          target.instance_authorized = true
          target.node_instance = @node_instance if @node_instance
          target
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
