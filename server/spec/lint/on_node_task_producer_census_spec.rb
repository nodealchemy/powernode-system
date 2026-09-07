# frozen_string_literal: true

require "spec_helper"
require_relative "../support/on_node_task_producers"
require "pathname"

# IMP-498cd7db446d — the census of WHO CAN QUEUE WORK FOR A NODE THAT MAY NOT
# BE THERE.
#
# ══ WHAT HAPPENED ═════════════════════════════════════════════════════════
#
# Fleet::DecisionEngine#dispatch_reconcile_task created a sync_modules
# System::Task for any instance that passed its self-managed and in-flight
# fences. Two such tasks, created 2026-09-06T03:18:02Z against instances whose
# agents last reported on 09-04, were still `pending` at progress 0 seventeen
# hours later while every other task in the surrounding three days completed in
# seconds. IMP-fb05226e89cb added NodeInstance#on_node_dispatch_refusal and put
# it in front of that dispatch; IMP-cdf18862a7c1 put it in front of the two MCP
# verbs that do the same thing for an operator.
#
# Those fixed the INSTANCES. Nothing fixed the CLASS. No guard says a further
# producer must consult the predicate, and the enumeration of producers is
# precisely the thing that rots.
#
# ══ WHY A LITERAL GREP CANNOT BUILD THIS CENSUS ═══════════════════════════
#
# #dispatch_reconcile_task passes `command: command` — a VARIABLE. A search for
# `command: "sync_modules"` does not see it, so the single most important
# producer is invisible to the obvious way of building this list. The scanner
# therefore treats "the command cannot be read statically" as a census
# OBLIGATION, not an absence. Fail closed.
#
# That decision paid immediately. Widening the scanner past
# `System::Task.create!` — the one spelling the original finding enumerated —
# surfaced THREE producers no prior pass had seen, one of them a live ungated
# path: Executors::ExecuteTask builds the row with `Task.new(attrs)` + `save!`
# from a params hash, reached by POST /api/v1/system/tasks, whose permitted
# params include :command and whose COMMANDS list contains sync_modules. It is
# censused below as a :gap, with an offer, rather than quietly omitted.
#
# ══ WHAT THIS DOES NOT COVER, SO A GREEN RUN IS NOT OVER-READ ═════════════
#
# COMMANDS. Scope is the two commands ExecutionDispatcher routes to the on-node
# reconcile runtimes: sync_modules and apply_config. That is NARROWER than
# ExecutionDispatcher::AGENT_DELEGATED_COMMANDS — upgrade_boot_image, the
# storage.* verbs, ci.module_build, ci.package_build, probe.module_smoke — and
# the difference is an open question recorded rather than silently resolved:
# sync_modules and apply_config are in COMMAND_REGISTRY, i.e. the SERVER
# executes them, while the AGENT_DELEGATED set is what the agent actually polls
# for. So "no agent will pull this" is literally true of the delegated set and
# only empirically true of these two. Offer 01a07861-96d8 carries that, with the
# evidence that the recorded stall mechanism is itself unproven.
#
# Note the practical consequence for this file's own coverage: the tree contains
# no literal `command: "apply_config"` producer at all — apply_config reaches
# System::Task only through the variable in #dispatch_reconcile_task — so the
# real-tree run exercises the literal arm with one command only. The synthetic
# self-tests cover the other.
#
# PATHS. app/, lib/ and db/ of this extension. Not the worker tree, not core,
# not other extensions. Verified empty of System::Task producers today, so this
# is a latent boundary, not a live hole — but it is a boundary, and
# "censuses every in-scope producer in the tree" below means these roots.
#
# ══ SHAPE ═════════════════════════════════════════════════════════════════
#
# Two-directional, because a one-directional guard rots into a list of things
# that used to be true: a producer missing from the census reddens, and a
# census entry whose site no longer exists reddens. Keys are path#method, never
# line numbers — two commits moved these very sites on the day this was
# written. Because a method can hold more than one construction, each entry
# also pins a COUNT: adding a second, ungated create! to an already-censused
# method must not be invisible.
#
# A :gated entry's evidence is checked against the GUARD SPAN — the text
# between the enclosing `def` and the construction, comments blanked — not the
# file. The first version checked the file, and an independent review showed
# that let the flagship gate be deleted while a comment four hundred lines away
# kept the census green.
RSpec.describe "on-node task producer census" do
  # Namespaced, following spec/lint/provider_type_writer_census_spec.rb: a bare
  # `CENSUS` inside a describe block is defined on Object, and this directory
  # already holds three census specs.
  module OnNodeTaskProducerCensus
    SERVER_ROOT = Pathname.new(__dir__).join("..", "..").cleanpath
    ROOTS = %w[app lib db].map { |d| SERVER_ROOT.join(d) }.freeze

    # :gated        — consults the liveness predicate before constructing.
    #                 `evidence` must appear in the GUARD SPAN.
    # :acknowledged — in scope, deliberately not gated, with a reason.
    # :out_of_scope — the command is unreadable here, and the command the site
    #                 can actually carry is not an on-node reconcile command.
    #                 Ratcheted: the file must contain no on-node literal.
    # :gap          — a real ungated producer. Must name a filed offer.
    #
    # The acknowledged reasons are DERIVED FROM READING the producers, not
    # transcribed: the operator's direction cited knowledge 01a0779f-e8c2 for
    # the recorded non-filings and that entry did not come back from
    # search_knowledge, so rather than cite a justification this session could
    # not open, each reason is the one its own code shows. That turned out to
    # matter — see the two entries below, whose first-draft justification an
    # independent review falsified.
    CENSUS = {
      "app/services/system/fleet/decision_engine.rb#dispatch_reconcile_task" => {
        disposition: :gated, sites: 1,
        evidence: "on_node_dispatch_refusal",
        why: "The autonomous producer, and the site behind the observed incident. Passes " \
             "`command: command`, so it is invisible to a literal search — censused by path " \
             "on purpose. Gated ahead of the in-flight check: if the agent is gone, " \
             "'a reconcile task is already in flight' is a true but misleading answer."
      },
      "app/services/ai/tools/system_fleet_tool.rb#dispatch_retemplate_convergence!" => {
        disposition: :gated, sites: 1,
        evidence: "on_node_dispatch_refusal",
        why: "system_update_node's convergence rung. Reports refusals in a third `skipped` " \
             "bucket rather than narrowing its LIVE_INSTANCE_SCOPE query, which is the " \
             "blast-radius definition it shares with TemplateApprovalPolicy."
      },
      "app/services/ai/tools/system_fleet_tool.rb#refresh_instance_modules" => {
        disposition: :gated, sites: 1,
        evidence: "offline_dispatch_refusal",
        why: "system_refresh_instance_modules. Takes the STATUS arm alone and warns on the " \
             "others: this is the operator-explicit repair path for the 2026-08-07 incident, " \
             "so refusing a silent-but-running node would trade a visible stuck task for a " \
             "refused repair, which is the worse failure."
      },
      "app/services/system/executors/execute_task.rb#perform" => {
        disposition: :gap, sites: 1,
        offer: "01a07872-3679",
        why: "POST /api/v1/system/tasks -> AutonomyGate -> ExecuteTask#perform builds the row " \
             "with Task.new(attrs) + save! from permitted params that include :command, and " \
             "System::Task::COMMANDS contains sync_modules and apply_config. So an on-node " \
             "task can be created for a silent instance with no liveness check anywhere on " \
             "the path. Found by widening this scanner past System::Task.create!; it was " \
             "absent from every prior enumeration of this defect. Whether the gate belongs " \
             "here or at a shared seam is the filed question."
      },
      "app/services/system/fulfillment_advance_orchestrator.rb#ensure_template_applied!" => {
        disposition: :acknowledged, sites: 1,
        offer: "01a07872-a383",
        why: "Queues the sync for an instance this flow just obtained. The FIRST-DRAFT reason " \
             "here said 'freshly provisioned, so it has not heartbeat yet by construction' — " \
             "an independent review falsified that: the pool fast path runs BEFORE " \
             "fresh_provision, and InstancePoolService#acquire! selected the OLDEST ready " \
             "member with no heartbeat check, so the target could be a member that had sat " \
             "ready for days with a dead agent. IMP-787c95be55a0 CLOSED that half at the " \
             "source: acquire! now refuses a member whose #on_node_dispatch_refusal / " \
             "#dormant_agent_reason answers, so the pool branch is handed a live member or " \
             "nothing. It stays acknowledged rather than gated because the site itself still " \
             "does not consult the predicate — and does not need to: its other branch is " \
             "fresh_provision, which a heartbeat gate really would refuse by construction."
      },
      "app/services/system/ai/skills/module_smoke_verify_executor.rb#compose_pairing!" => {
        disposition: :acknowledged, sites: 1,
        offer: "01a07872-a383",
        why: "Same producer shape and the same falsified premise, more starkly: the standalone " \
             "path has NO fresh-provision branch at all, it is InstancePoolService.acquire! " \
             "and nothing else, so 'the target is one it just provisioned' was never true " \
             "here. That makes it the entry FULLY covered by IMP-787c95be55a0 — every member " \
             "this path can reach now comes through the gated acquire!. Acknowledged rather " \
             "than gated because the gate is at the allocator, one call frame up, where every " \
             "pool consumer shares it, rather than restated at this site."
      },
      "app/services/system/native_module_build_orchestrator.rb#create_build_task" => {
        disposition: :out_of_scope, sites: 1,
        why: "Unresolvable to the scanner (`command: @batch.member_task_command`) and therefore " \
             "censused, but ModuleBuildBatch#member_task_command returns only the two frozen " \
             "constants ci.package_build / ci.module_build — AGENT_DELEGATED, not on-node " \
             "reconcile. It also targets a CI-runner lease's instance, already selected as live."
      },
      "app/services/system/storage/nfs_export_manager.rb#dispatch_task" => {
        disposition: :out_of_scope, sites: 1,
        why: "Unresolvable (`command: command`, a method parameter), but every caller passes " \
             "the literal storage.exports.apply, which is in AGENT_DELEGATED_COMMANDS rather " \
             "than the on-node reconcile pair. Whether the gate should extend to the delegated " \
             "family is offer 01a07861-96d8, not a silent omission."
      },
      "app/services/system/storage/smb_user_manager.rb#dispatch_task" => {
        disposition: :out_of_scope, sites: 1,
        why: "Same as nfs_export_manager#dispatch_task — a storage.* verb passed as a method " \
             "parameter, agent-delegated rather than an on-node reconcile command."
      },
      "app/controllers/concerns/system/node_instance_gating.rb#create_instance_operation" => {
        disposition: :out_of_scope, sites: 1,
        why: "The association form (`current_account.system_tasks.create(command: command, ...)`) " \
             "— non-bang, no System::Task receiver, variable command, invisible three ways over, " \
             "which is why the scanner matches construction rather than one spelling. Today it " \
             "carries only the control verbs start/stop/reboot/terminate/restart; " \
             "ExecutionDispatcher's own comment names it as a path that never meets the gate, " \
             "so if it ever grows an on-node command the ratchet below reddens."
      },
      "app/controllers/api/v1/system/worker_api/tasks_controller.rb#create" => {
        disposition: :out_of_scope, sites: 1,
        why: "`operable.tasks.build(operation_params)` — the worker-authenticated creation " \
             "endpoint. Unresolvable (the command arrives in permitted params). Out of scope " \
             "because its operable is resolved through #find_operable, which scopes to nodes " \
             "this worker manages, and because the worker creates tasks it is itself about to " \
             "execute rather than queueing work for a third party. If that changes it becomes " \
             "the same shape as the ExecuteTask gap above."
      }
    }.freeze

    DISPOSITIONS = %i[gated acknowledged out_of_scope gap].freeze

    def self.read(rel)
      path = SERVER_ROOT.join(rel)
      raise "census target missing: #{rel}" unless path.exist?

      path.read
    end
  end

  let(:sites)      { OnNodeTaskProducers.scan_roots(*OnNodeTaskProducerCensus::ROOTS) }
  let(:in_scope)   { OnNodeTaskProducers.in_scope(sites) }
  let(:by_key)     { in_scope.group_by(&:key) }
  let(:found_keys) { by_key.keys.sort }

  # ── Vacuity guards ────────────────────────────────────────────────────────
  # Every equality below is trivially satisfied by an empty scan. This project
  # has shipped exactly that mistake; these are the positive controls.

  it "finds a plausible number of System::Task construction sites" do
    expect(sites.size).to be >= 20,
                          "the construction scan collapsed — every census equality below would be vacuous"
  end

  it "finds both shapes it exists to classify" do
    expect(in_scope.count { |s| s.shape == :literal }).to be >= 3,
                                                          "no on-node LITERAL producers found — the literal arm is broken"
    expect(in_scope.count { |s| s.shape == :unresolvable }).to be >= 5,
                                                               "no UNRESOLVABLE producers found — the arm that catches the incident's own producer is broken"
  end

  # The operator's explicit requirement, and the entry whose silent
  # disappearance would be indistinguishable from a dead scanner.
  it "finds the variable producer that a literal grep cannot see, by path" do
    engine = in_scope.find { |s| s.path.end_with?("fleet/decision_engine.rb") }

    expect(engine).not_to be_nil,
                          "DecisionEngine#dispatch_reconcile_task is missing from the scan — it passes " \
                          "`command: command`, so if the unresolvable arm regresses this census goes quiet " \
                          "about the exact producer that caused the incident"
    expect(engine.method_name).to eq("dispatch_reconcile_task")
    expect(engine.shape).to eq(:unresolvable)
  end

  # ── Direction 1: a NEW producer must be censused ──────────────────────────

  it "censuses every in-scope producer in the tree" do
    uncensused = found_keys - OnNodeTaskProducerCensus::CENSUS.keys

    expect(uncensused).to eq([]), <<~MSG
      A System::Task construction queues an on-node reconcile command (or a command this
      scanner cannot read) and is not in the census:

        #{uncensused.join("\n  ")}

      Consult NodeInstance#on_node_dispatch_refusal before constructing and add a :gated
      entry, or add an :acknowledged / :out_of_scope / :gap entry saying why. An
      unclassified producer is how the gap reopens.
    MSG
  end

  # ── Direction 2: a STALE entry must be removed ────────────────────────────

  it "carries no census entry whose producer no longer exists" do
    stale = OnNodeTaskProducerCensus::CENSUS.keys - found_keys

    expect(stale).to eq([]), <<~MSG
      These census entries name a producer the scanner no longer finds:

        #{stale.join("\n  ")}

      Either the site was deleted or renamed (update the entry), or the scanner stopped
      seeing it (fix the scanner). A one-directional census rots into a list of things that
      used to be true, which is why this direction exists.
    MSG
  end

  # ── Direction 3: a SECOND construction in a censused method ───────────────

  it "pins how many constructions each censused method holds" do
    drifted = OnNodeTaskProducerCensus::CENSUS.filter_map do |key, entry|
      actual = by_key.fetch(key, []).size
      next if actual == entry.fetch(:sites)

      "#{key}: census says #{entry[:sites]}, tree has #{actual}"
    end

    expect(drifted).to eq([]), <<~MSG
      #{drifted.join("\n  ")}

      The key is path#method with no ordinal, so without this a SECOND, ungated
      construction added to an already-censused method would be completely invisible —
      same key, already censused, both directions green.
    MSG
  end

  # ── The entries cannot lie ────────────────────────────────────────────────

  it "declares a known disposition and a real explanation for every entry" do
    OnNodeTaskProducerCensus::CENSUS.each do |key, entry|
      expect(OnNodeTaskProducerCensus::DISPOSITIONS).to include(entry[:disposition]),
                                 "#{key}: unknown disposition #{entry[:disposition].inspect}"
      expect(entry[:why].to_s.length).to be > 80,
                                         "#{key}: an entry must explain itself, not just name itself"
    end
  end

  it "requires a filed offer on every :gap entry" do
    OnNodeTaskProducerCensus::CENSUS.select { |_, e| e[:disposition] == :gap }.each do |key, entry|
      expect(entry[:offer].to_s).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}\z/),
                                    "#{key}: a :gap is a known-ungated producer and must name the offer that tracks it"
    end
  end

  # The strong form: the predicate must appear between the enclosing `def` and
  # the construction, with comments blanked. A file-level check let either
  # gate in system_fleet_tool.rb be deleted while the other method's call, or
  # a comment, kept this green.
  it "proves every :gated producer consults the predicate BEFORE constructing" do
    OnNodeTaskProducerCensus::CENSUS.select { |_, e| e[:disposition] == :gated }.each do |key, entry|
      file = key.split("#").first
      source = OnNodeTaskProducerCensus.read(file)
      site = by_key.fetch(key).first
      span = OnNodeTaskProducers.guard_span(source, site)

      expect(span.include?(entry.fetch(:evidence))).to be(true), <<~MSG
        #{key} is censused as :gated on #{entry[:evidence]}, and that name does not appear
        between its `def` and its System::Task construction (comments excluded).

        Either the gate was removed — in which case this producer is queueing work for nodes
        that cannot run it again — or it moved somewhere that no longer guards this call.
      MSG
    end
  end

  # The ratchet for :out_of_scope. Each of those sites passes its command in
  # from somewhere the scanner cannot follow, so the claim "it can only carry
  # a non-on-node command" is not statically provable. What IS checkable, and
  # what kills the realistic mutant — a fourth caller passing "sync_modules"
  # to storage's private dispatch_task — is that the file mentions no on-node
  # command at all.
  it "keeps every :out_of_scope producer's file free of on-node command literals" do
    OnNodeTaskProducerCensus::CENSUS.select { |_, e| e[:disposition] == :out_of_scope }.each do |key, _entry|
      file = key.split("#").first
      source = OnNodeTaskProducerCensus.read(file)

      OnNodeTaskProducers::ON_NODE_COMMANDS.each do |command|
        expect(source.include?(%("#{command}"))).to be(false), <<~MSG
          #{key} is censused :out_of_scope on the grounds that it cannot carry an on-node
          reconcile command, and #{file} now contains the literal "#{command}".

          If a caller in this file passes it to that producer, the site is in scope and needs
          a gate — reclassify the entry rather than relaxing this check.
        MSG
      end
    end
  end

  # ── The detector self-tests ───────────────────────────────────────────────
  #
  # Load-bearing, not decoration. On 2026-09-06 a plan-cache lint in this same
  # tree scanned the spec file instead of the migration it required, matched
  # nothing, passed green, and would have missed the very offender that
  # motivated it — caught only by mutating the real offender. These are the
  # standing version of that mutation, and each one below corresponds to a way
  # an earlier draft of this scanner was actually wrong.

  describe "the scanner itself" do
    def scan(source)
      OnNodeTaskProducers.in_scope(OnNodeTaskProducers.scan("app/services/synthetic.rb", source))
    end

    it "FIRES on a synthetic ungated producer" do
      found = scan(<<~RUBY)
        module Synthetic
          def queue_it(instance)
            ::System::Task.create!(
              account: account, operable: instance,
              command: "sync_modules", status: "pending", options: {}
            )
          end
        end
      RUBY

      expect(found.map(&:key)).to eq([ "app/services/synthetic.rb#queue_it" ])
      expect(found.first.command).to eq("sync_modules")
    end

    # The tree has no literal apply_config producer, so without this the second
    # half of ON_NODE_COMMANDS is never exercised and could be dropped silently.
    it "FIRES on the apply_config half of ON_NODE_COMMANDS" do
      found = scan(<<~RUBY)
        module Synthetic
          def queue_config(instance)
            ::System::Task.create!(operable: instance, command: "apply_config")
          end
        end
      RUBY

      expect(found.map(&:command)).to eq([ "apply_config" ])
    end

    it "FIRES on the variable shape a literal grep cannot see" do
      found = scan(<<~RUBY)
        module Synthetic
          def dispatch(instance, command:)
            ::System::Task.create!(
              account: account, operable: instance,
              command: command, status: "pending", options: {}
            )
          end
        end
      RUBY

      expect(found.map(&:key)).to eq([ "app/services/synthetic.rb#dispatch" ])
      expect(found.first.shape).to eq(:unresolvable)
    end

    # The two construction spellings that hid real producers in this tree.
    it "FIRES on Task.new and on the association form" do
      found = scan(<<~RUBY)
        module Synthetic
          def via_new(attrs)
            task = ::System::Task.new(attrs)
            task.save!
          end

          def via_association(command)
            current_account.system_tasks.create(command: command, status: "pending")
          end
        end
      RUBY

      expect(found.map(&:key)).to contain_exactly(
        "app/services/synthetic.rb#via_new",
        "app/services/synthetic.rb#via_association"
      )
      expect(found.map(&:shape).uniq).to eq([ :unresolvable ])
    end

    it "FIRES on a construction with no readable command, rather than skipping it" do
      found = scan(<<~RUBY)
        module Synthetic
          def splatted(instance, attrs)
            ::System::Task.create!(**attrs)
          end

          def neighbour(instance)
            ::System::Task.create!(operable: instance, command: "storage.chown")
          end
        end
      RUBY

      # #splatted must NOT read #neighbour's command. The byte-window version
      # of this scanner did exactly that, silently dropping the fail-closed
      # case — and the two creates in storage/gateway_provisioning_service.rb
      # sit 460 bytes apart, so the condition is live in the tree.
      expect(found.map(&:key)).to eq([ "app/services/synthetic.rb#splatted" ])
      expect(found.first.shape).to eq(:unresolvable)
    end

    it "reads the whole `command:` key, not a suffix of a longer one" do
      found = scan(<<~RUBY)
        module Synthetic
          def decoyed(instance)
            ::System::Task.create!(
              operable: instance, sub_command: "noop", command: "sync_modules"
            )
          end
        end
      RUBY

      expect(found.map(&:command)).to eq([ "sync_modules" ])
    end

    it "does NOT fire on an out-of-scope literal command" do
      found = scan(<<~RUBY)
        module Synthetic
          def reboot_it(instance)
            ::System::Task.create!(
              account: account, operable: instance,
              command: "restart", status: "pending", options: { "unit" => "x" }
            )
          end
        end
      RUBY

      expect(found).to eq([])
    end

    it "does NOT fire on the construction appearing inside a comment" do
      # The real false positive the first draft had:
      # governance/policy_declarations.rb discusses, in prose, which producers
      # call System::Task.create! directly.
      found = scan(<<~RUBY)
        module Synthetic
          # Every in-process producer calls System::Task.create! directly with
          # command: "sync_modules" and never meets the gate.
          def documented_only(instance)
            nil
          end
        end
      RUBY

      expect(found).to eq([])
    end

    # The other half of that trade-off, and the one the first draft failed to
    # test discriminatingly: blanking too much would HIDE a call site, which
    # is the dangerous direction. The first attempt put the comment AFTER the
    # closing paren, where broadening the blanker to /#.*$/ destroys nothing —
    # so the mutant survived. The shape that actually discriminates is a `#`
    # inside a STRING earlier on the same line, which a naive blanker cannot
    # tell from a comment and which would take the whole construction with it.
    it "still fires on a construction preceded on its line by a # inside a string" do
      found = scan(<<~'RUBY')
        module Synthetic
          def queue_it(instance)
            Rails.logger.info("channel #general") and ::System::Task.create!(operable: instance, command: "sync_modules")
          end
        end
      RUBY

      expect(found.map(&:command)).to eq([ "sync_modules" ]),
                                      "the comment blanker ate a real construction — blanking beyond whole-line " \
                                      "comments hides call sites, which is the direction that loses the guard"
    end

    it "still fires on a construction whose own line carries string interpolation" do
      found = scan(<<~'RUBY')
        module Synthetic
          def queue_it(instance)
            ::System::Task.create!(operable: instance, description: "sync #{instance.name}", command: "sync_modules")
          end
        end
      RUBY

      expect(found.map(&:command)).to eq([ "sync_modules" ])
    end

    it "does NOT fire on a construction spelled inside a string literal" do
      # authorize_worker_permission!("system.tasks.create") really does match
      # the association form textually.
      found = scan(<<~RUBY)
        module Synthetic
          def authorize
            require_permission("system.tasks.create")
          end
        end
      RUBY

      expect(found).to eq([])
    end
  end

  describe "the guard span" do
    let(:source) do
      <<~RUBY
        module Synthetic
          def gated(instance)
            return if instance.on_node_dispatch_refusal

            ::System::Task.create!(operable: instance, command: "sync_modules")
          end

          def ungated(instance)
            ::System::Task.create!(operable: instance, command: "sync_modules")
          end
        end
      RUBY
    end

    let(:scanned) { OnNodeTaskProducers.scan("app/services/synthetic.rb", source) }

    it "sees a predicate consulted in the same method, before the construction" do
      site = scanned.find { |s| s.method_name == "gated" }

      expect(OnNodeTaskProducers.guard_span(source, site)).to include("on_node_dispatch_refusal")
    end

    # The finding that forced the span: a file-level check passes here because
    # the OTHER method is gated.
    it "does NOT see a neighbouring method's predicate" do
      site = scanned.find { |s| s.method_name == "ungated" }

      expect(OnNodeTaskProducers.guard_span(source, site)).not_to include("on_node_dispatch_refusal")
    end

    it "does NOT accept a predicate that appears only in a comment" do
      commented = <<~RUBY
        module Synthetic
          def looks_gated(instance)
            # on_node_dispatch_refusal is consulted by the caller, honest
            ::System::Task.create!(operable: instance, command: "sync_modules")
          end
        end
      RUBY
      site = OnNodeTaskProducers.scan("app/services/synthetic.rb", commented).first

      expect(OnNodeTaskProducers.guard_span(commented, site)).not_to include("on_node_dispatch_refusal")
    end
  end
end
