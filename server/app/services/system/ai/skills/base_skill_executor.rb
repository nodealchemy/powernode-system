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

          # True when the descriptor asks for an approval gate. The predicate
          # exists so `requires_approval` has exactly one reader
          # (IMP-7e2bdc1774e4): before this, the flag was DECLARED and read by
          # NOBODY.
          #
          # It reads the DESCRIPTOR, which is narrower than a grep for
          # `requires_approval: true` under this directory: that grep returns 17
          # files, but three of the hits are not descriptor keys —
          # ScaleProjectExecutor (:501) and RollingModuleUpgradeExecutor (:169)
          # put the flag on a RESULT payload ("travels with the RESULT", they
          # both say) and template_approval_policy.rb is a policy class, not an
          # executor. Fourteen executors actually declare the descriptor key,
          # and those fourteen are what this gate covers.
          def gate_required?
            descriptor[:requires_approval] == true
          end

          # The Ai::InterventionPolicy category this executor's gate resolves.
          #
          # Declarable per-executor — `skill_descriptor(action_category: "...")`
          # flows through `**extras`. DECLARE IT whenever the operator control
          # for this action already exists under another name, so the gate and
          # the modal resolve one row rather than two spellings of it. Two do:
          # ServiceDiscoveryComposerExecutor (registered as
          # system.service_discovery_compose, not ...composer) and
          # BootImageDriftRolloutExecutor (the tick loop already gates it as
          # system.node_boot_image_drift). Adding a second spelling instead is
          # the exact defect IMP-eb60db901f5f cleaned up.
          #
          # Otherwise "<domain>.<skill name>". That derivation matches an
          # existing registered category only where the descriptor name and the
          # registered name coincide — system.multi_tenant_isolation is the one
          # gated executor for which it did — so every other derived category
          # had to be REGISTERED in lib/powernode_system/engine.rb for this gate
          # to be tunable at all (see the note there: registration is what
          # System::AutonomyActions#update passes, and what
          # db/seeds/system_autonomy_orphan_cleanup.rb spares).
          #
          # A category NO active policy row matches resolves to
          # Ai::InterventionPolicyService#default_policy, which is
          # "require_approval" — so an executor that declares the flag and has
          # no operator policy gates rather than proceeds. That is the fail-safe
          # direction and it is what the descriptor already promised.
          def action_category
            descriptor[:action_category].presence ||
              "#{descriptor[:domain]}.#{descriptor[:name]}"
          end

          # Ai::AutonomyGate replay entry point. Ai::DeferredOperation
          # #execute_now! calls `executor_constant.execute(params,
          # deferred_operation:)` both for a policy that auto-proceeds and,
          # later, for one an approval chain released — so without this method
          # every approval parked by #gate_action! would be a dead end.
          #
          # `gated: true` is what stops the replay from parking a SECOND
          # approval for the decision that just completed.
          def execute(params, deferred_operation:)
            requested_by = deferred_operation.requested_by

            built = new(account: deferred_operation.account,
                        agent: deferred_operation.ai_agent,
                        user: requested_by)

            # A replay is a RESUMED EXTERNAL request, never an in-process system
            # caller. Left alone, a userless origin — an MCP instance principal
            # carries no User — would satisfy #internal_caller? on the way back
            # and inherit the reconciler's in-process bypass for every tool the
            # executor nests, re-opening IMP-0e6b216de843 through the approval
            # door. Marking it instance-authorized keeps #internal_caller? false
            # and re-arms Mcp::Principal's destructive deny overlay on the
            # nested calls, which is the conservative direction and matches the
            # posture the ORIGINAL call had.
            built.instance_authorized = true if requested_by.nil?

            outcome = built.execute(gated: true, **(params || {}).to_h.symbolize_keys)
            resume_composed_plan(deferred_operation, outcome)
            outcome
          end

          # COMPOSED-PLAN RESUME (APO-1f, IMP-117b34656921) — the open question
          # IMP-7e2bdc1774e4 left behind.
          #
          # A provisioning step whose executor parked is sitting in
          # Ai::Provisioning::SkillCompositionRunner::PARKED_STATUS waiting on
          # exactly this replay. #execute_now! runs us BEFORE it stamps its own
          # row, so the runner is handed the outcome directly rather than
          # re-reading a row that still says `executing`.
          #
          # Best-effort by construction: the replay itself has already applied
          # (or refused) the operation, and a resume that raises must not turn a
          # completed approval into a failed one. A parked STEP that misses its
          # resume is recoverable — re-dispatching it lands on
          # #execute_step!, which reads the released operation off the row.
          #
          # Extension → core is the allowed direction; the runner is core, and
          # its class method is a no-op for the common case where the parked
          # operation belongs to no plan at all (a direct MCP or REST call).
          def resume_composed_plan(deferred_operation, outcome)
            return if deferred_operation.nil?
            return unless defined?(::Ai::Provisioning::SkillCompositionRunner)

            ::Ai::Provisioning::SkillCompositionRunner.resume_parked_step(
              deferred_operation: deferred_operation, result: outcome
            )
          rescue StandardError => e
            ::Rails.logger.error(
              "[#{name}] composed-plan resume failed for deferred_operation " \
              "#{deferred_operation&.id}: #{e.class}: #{e.message}"
            )
            nil
          end
          # `private`, not `private_class_method`: inside `class << self` these
          # ARE the singleton's instance methods, and private_class_method would
          # look for the method one level further up.
          private :resume_composed_plan
        end

        # Policy verdicts that mean "run it now". Same pair
        # System::Fleet::DecisionEngine uses for the tick loop, so the two
        # gates agree on what counts as automatic.
        AUTO_EXECUTE_POLICIES = %w[auto_approve notify_and_proceed].freeze

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

        # Set by #executor on every peer this executor nests. A nested peer is
        # NOT an entry point: the operator-visible unit is the outermost call,
        # and an approval parked halfway down a composition is worse than
        # useless — Ai::DeferredOperation#execute_now! replays the CHILD alone,
        # so the composer's remaining steps never run and the plan cannot be
        # resumed by approving it. Nested peers therefore never park. They are
        # still REFUSED by a `block` row on their own category, so an operator's
        # hard "no" holds on the composed door as well as the direct one.
        attr_writer :nested

        def initialize(account:, agent: nil, user: nil)
          raise ArgumentError, "account is required" if account.nil?

          @account = account
          @agent   = agent
          @user    = user
          @instance_authorized = false
          @node_instance = nil
          @nested = false
        end

        # Public entry point. Validates required inputs against the descriptor,
        # resolves the approval gate, audit-logs start, dispatches to subclass
        # `#perform`, audit-logs finish, and wraps any uncaught exception in a
        # `failure(...)` result.
        #
        # `gated:` is the CALLER'S assertion that policy was already resolved
        # for this invocation. System::Fleet::DecisionEngine resolves it itself
        # before building the executor (#invoke_skill for a side-effectful
        # binding, and #execute_approved! replaying an approved request), so
        # those calls pass it and a second evaluation here would park an
        # approval for a decision already made. The db/seeds/smoke_test_*
        # scripts pass it too: an operator running a smoke seed by hand IS the
        # decision. It is NOT a general escape hatch — every other door leaves
        # it false. Bound as an explicit keyword so it never reaches
        # #validate_inputs! or #perform.
        def execute(gated: false, **inputs)
          # Validation FIRST: a call that could only ever fail must not park an
          # approval an operator then has to dispose of.
          validate_inputs!(inputs)

          unless gated
            gate = gate_action!(inputs)
            return gate if gate
          end

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

        # THE APPROVAL GATE, evaluated BEFORE #perform (APO-1c,
        # IMP-7e2bdc1774e4).
        #
        # Returns nil to let the run continue in-process, or the result hash the
        # caller must return instead of performing. Never nil-on-refusal: an
        # ambiguous return here would be a silent double execution.
        #
        # Why the verdict is resolved SEPARATELY from Ai::AutonomyGate.
        # AutonomyGate decides AND executes — on auto_approve /
        # notify_and_proceed it runs the operation through
        # Ai::DeferredOperation#execute_now!, which rebuilds the executor from
        # the stored row. A rebuild cannot carry the caller provenance THIS
        # instance holds (`instance_authorized` / `node_instance`), and #tool
        # reads exactly that to decide whether a nested tool gets the in-process
        # bypass (IMP-0e6b216de843). Resolving the policy first keeps the common
        # "policy says go" case on this instance with its provenance intact, and
        # sends only the verdicts that need a durable, resumable row — approval
        # and refusal — through the gate.
        #
        # Fail-safe by construction: anything that is not an explicit
        # auto-execute verdict goes to the gate, including the "no policy row
        # matched" default, so a NEW skill declaring requires_approval is gated
        # from its first call rather than from whenever someone seeds a row.
        def gate_action!(inputs)
          return nil unless self.class.gate_required?

          policy = resolved_policy
          # An auto-execute verdict runs here, on THIS instance, without a
          # durable row. Ai::AutonomyGate's own docstring says it writes an
          # Ai::DeferredOperation "in every case (audit trail)"; that promise is
          # about the gate, and this branch deliberately does not reach it, so
          # the audit for an auto-approved skill run is the executor's own
          # #audit_log_start / #audit_log_finish pair and NOT a row in the
          # Autonomy deferred-operations view. Trading the row for the caller's
          # provenance is the point — see the paragraph above.
          return nil if AUTO_EXECUTE_POLICIES.include?(policy)

          # A nested peer never parks (see attr_writer :nested). Only a `block`
          # row still refuses, and it goes through the gate below so the refusal
          # gets the same durable record a direct one does.
          return nil if @nested && policy != "block"

          category = self.class.action_category
          result = ::Ai::AutonomyGate.evaluate(
            action_category: category,
            executor_class: self.class.name,
            params: inputs,
            account: @account,
            agent: @agent,
            requested_by: @user,
            description: self.class.descriptor[:description]
          )

          case result.decision
          when :proceed
            # Reachable only when the gate's OWN resolution disagrees with
            # #resolved_policy above — a policy row written between the two
            # reads, or a scope this executor resolves differently. NOT the
            # core-mode fall-through in
            # Ai::AutonomyGate#require_approval_or_proceed: that arm is guarded
            # on `defined?(::Ai::ApprovalChain)`, and Ai::ApprovalChain is a
            # CORE model (server/app/models/ai/approval_chain.rb), so it is
            # always loaded here. Handled rather than raised because the gate
            # already RAN the operation through the class-level replay by the
            # time it says :proceed — its result IS this call's, and dropping it
            # would double-execute.
            result.result.is_a?(Hash) ? result.result
                                      : failure("Gate proceeded for #{category} but returned no executor result")
          when :pending
            pending_result(category, result)
          else
            failure(result.error || "Action #{category} is blocked by policy")
          end
        end

        # THE PLATFORM'S THIRD OUTCOME, not a failure (APO-1f,
        # IMP-117b34656921).
        #
        # APO-1c returned `failure(...)` here. That was deliberate at the time —
        # Ai::Provisioning::SkillCompositionRunner keys on `success: false` to
        # STOP, so a truthful `success: true` would have let a composed plan
        # continue past a step nothing applied — but it made the SAME parked
        # category answer two different things depending on the door: SdwanTool
        # (and every BaseTool declared gate) already returned
        # `success: true` + `data.pending`, the shape the MCP outputSchema
        # advertises (Ai::Tools::BaseTool::PENDING_RESULT_PROPERTIES), while the
        # ingress tool and the REST controllers handed the caller a FAILURE for
        # an action an operator was still deciding. An agent reads that as
        # "didn't work" and retries.
        #
        # Both halves landed together: this envelope, and consumers that key on
        # `pending` — SkillCompositionRunner now PARKS the step
        # (PARKED_STATUS) rather than completing or failing it, and resumes it
        # from .execute below when the approval releases.
        #
        # `pending: true` rides at the TOP LEVEL as well as inside `data`. The
        # data body is the wire contract every MCP door passes through
        # unchanged; the top-level copy is for in-process consumers that never
        # see a tool envelope, so keying on it needs no dig into a payload
        # whose shape a subclass could legitimately vary.
        def pending_result(category, result)
          {
            success: true,
            pending: true,
            data: ::Ai::Tools::BaseTool.pending_payload(
              action_category: category,
              deferred_operation: result.deferred_operation,
              approval_request: result.approval_request,
              message: pending_message(category, result)
            )
          }
        end

        # The human-readable half of the envelope above: the identifiers ride in
        # `data` structurally, and this sentence is what a chat surface renders.
        def pending_message(category, result)
          id = result.approval_request&.id || result.deferred_operation&.id
          base = "Approval required: #{category}"
          id.present? ? "#{base} (approval_request #{id})" : base
        end

        # The policy verdict alone, with none of the gate's side effects.
        def resolved_policy
          ::Ai::InterventionPolicyService
            .new(account: @account)
            .resolve(action_category: self.class.action_category, agent: @agent, user: @user)[:policy].to_s
        rescue StandardError => e
          # FAIL CLOSED. An unresolvable policy is not permission — hand the
          # call to the gate, which parks it where an operator can see it.
          Rails.logger.error(
            "[#{self.class.name}] policy resolution failed, gating: #{e.class}: #{e.message}"
          )
          "require_approval"
        end

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
        # The nested marker travels with it (IMP-7e2bdc1774e4): a peer built
        # here is a step of THIS run, not a door of its own, so it may be
        # blocked by its own policy but never parks an approval. Marked
        # unconditionally — an UNGATED composer nests just as inseparably as a
        # gated one, and a child that parked under it would strand the composer
        # mid-way with an approval whose replay rebuilds only the child.
        def executor(executor_class, **overrides)
          built = executor_class.new(account: @account, agent: @agent, user: @user, **overrides)
          # Guarded exactly like #mark_instance_provenance below: a child that
          # declares no gate has nothing to mark, and sending it the message
          # anyway would widen what every composer's collaborators must accept
          # for no behavioural gain.
          built.nested = true if gate_declaring?(executor_class)
          mark_instance_provenance(built)
        end

        # `gate_required?` reads the descriptor, and an intermediate base class
        # (System::Ai::Skills::CrudFactory) deliberately raises there rather
        # than returning nil — a composer nesting one must not blow up on the
        # question.
        def gate_declaring?(executor_class)
          executor_class.respond_to?(:gate_required?) && executor_class.gate_required?
        rescue NotImplementedError
          false
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
