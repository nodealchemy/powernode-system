# frozen_string_literal: true

require "rails_helper"

# IMP-c16864f5a1cd — PINS today's disjointness between the two lanes, and
# reds the day someone introduces an overlap.
#
# THE FAILURE THIS GUARDS AGAINST
#
# Two lanes answer "what happens with no policy row for this category?"
# differently:
#   * a category System::Fleet::DecisionEngine (or another
#     System::Autonomy::ActionCategoryRouter) ROUTES, gated through
#     `gate_action!`, BLOCKS loudly with GATE_POLICY_MISSING when its row is
#     missing — System::Autonomy::RoutedLaneGuard's whole purpose.
#   * a category reached through `Ai::GatedActions#gate!` /
#     `#gate_create!` / `#gate_update!`, or a direct `Ai::AutonomyGate.evaluate`
#     call, PARKS (decision :pending) when its row is missing — proven in
#     autonomy_gate_spec.rb and, for a real call site, in
#     autonomy_gate_unseeded_lane_reachability_spec.rb.
#
# Both are correct fail-safes in isolation. The defect is BLOCK-VS-PARK, not
# block-vs-fail-open (the "one SIGNAL_BINDINGS edit away from fail-open"
# framing this offer started with does not hold — see that spec and the
# hardening in autonomy_gate.rb for why). If the SAME category were ever
# claimed by both a routed lane and a direct gate! call site, a missing row
# would refuse loudly on one path and quietly park on the other — an operator
# reading the loud GATE_POLICY_MISSING block would reasonably conclude the
# action is governed, while the direct-gate path silently queues an approval
# nobody was told to expect.
#
# WHY DISCOVERY, NOT A HAND-WRITTEN LIST
#
# System::Autonomy::ActionCategoryRouter and RoutedLaneGuard both learned this
# lesson already (IMP-7a6c9a70e050, IMP-b400ec1a2df8): a hand list of "the
# known call sites" drifts the moment a new one is added and nobody remembers
# this file exists. So the direct-gate side is DISCOVERED the same way those
# two discover their routers/gates — by scanning this extension's own source
# for the call shapes (`gate!(`, `gate_create!(`, `gate_update!(`, or a bare
# `::Ai::AutonomyGate.evaluate(`) and extracting each `action_category:`
# argument found near one.
#
# THE DISCOVERY GAP THIS SPEC DOES NOT CLOSE, STATED PLAINLY
#
# `Ai::AutonomyGate`'s own class doc says it is "NOT A CHOKE POINT... coverage
# is therefore whatever the call sites happen to be... nothing in this file
# could tell you that." This spec inherits exactly that limit:
#   * it is bounded to extensions/system, for the same reason
#     action_category_router_spec.rb is — extensions/private/* has its own
#     lifecycle and would fail this in any clone without private extensions;
#   * a category value that is neither a string literal, an interpolated
#     string with a static prefix, nor a `Klass::CONST` path (i.e. built up
#     through a local variable, a method call, or a hash lookup with no
#     resolvable literal) cannot be resolved from source and FAILS this spec
#     loudly rather than being silently skipped — a human has to teach the
#     resolver the new shape or supply a literal it can read. The one
#     currently known exception is a plain passthrough (`action_category:
#     action_category`, SdwanTool's `#gated_result` helper) — the helper
#     itself carries no category and every one of its call sites supplies a
#     resolvable literal or constant, which this scan finds independently as
#     its own match;
#   * it says nothing about core, or any OTHER extension, calling
#     `Ai::AutonomyGate.evaluate` with one of DecisionEngine's routed
#     categories. Closing that fully would require scanning outside this
#     extension's boundary, which the existing RoutedLaneGuard/
#     ActionCategoryRouter specs also deliberately do not do;
#   * a FIFTH direct-gate shape exists and this scan cannot see it:
#     `Ai::Tools::BaseTool#dispatch` (base_tool.rb:629, core) resolves a
#     `declare_action` declaration and, for one with gate wiring
#     (executor_class/gate_context/on_proceed), calls
#     `run_through_autonomy_gate(declaration, params)` (~base_tool.rb:725)
#     with `declaration[:action_category]` — the same Ai::AutonomyGate,
#     same park-on-missing-row semantics as the four shapes above. This is
#     NOT mechanically detectable from this scan for three independent
#     reasons: the gate call lives in CORE (`BaseTool#dispatch`), outside
#     DGC_SERVICES_ROOT entirely; the dispatcher resolves the declaration
#     through a runtime hash lookup (`declarations[params[:action]]` or
#     equivalent) rather than a literal at the call site, so there is
#     nothing for a source scan to anchor on even if core were in scope;
#     and the actual gated-vs-not behaviour varies per declaration
#     (`ungated_when`/`human_only`), so "declares an action_category" alone
#     does not imply "reaches AutonomyGate" the way it does for the other
#     four shapes. A KNOWN, CONFIRMED LIVE INSTANCE of this fifth shape:
#     `System::Ai::Skills::ReplaceInstanceExecutor`'s `declare_action
#     "system_replace_instance", action_category: "system.instance_replace"`
#     (~replace_instance_executor.rb:128, full gate wiring) is exercised
#     through `Ai::Tools::SystemFleetTool` (system_fleet_tool.rb:976) and
#     overlaps `System::Fleet::DecisionEngine::SIGNAL_BINDINGS`
#     (decision_engine.rb:225) on the identical category — the same
#     block-vs-park axis as the accepted sdwan_vip_failover overlap below,
#     confirmed by a reviewer tracing `BaseTool#dispatch` directly rather
#     than inferred from this scan. Recorded as a learning (not this spec's
#     allowlist, since this spec cannot see the shape that causes it) —
#     see the create_learning entry cross-referencing offer
#     01a0bced-2351-764f-99a3-ef25362279eb.
RSpec.describe "direct Ai::AutonomyGate call sites vs. System::Fleet::DecisionEngine.routed_action_categories (IMP-c16864f5a1cd)" do
  DGC_SERVICES_ROOT = Rails.root.join("../extensions/system/server/app").cleanpath

  # The four call SHAPES that reach Ai::AutonomyGate directly rather than
  # through a `gate_action!` reconcile gate. `gate_action!` itself never
  # matches: none of these four substrings appear inside it.
  DGC_CALL = /(?:\bgate!|\bgate_create!|\bgate_update!|::Ai::AutonomyGate\.evaluate)\s*\(/

  # A definition line (`def gate!` in the core concern, `def self.evaluate` on
  # AutonomyGate itself) is a declaration of the shape, not a use of it, and
  # carries no resolvable category value. Excluded so this scan — bounded to
  # extensions/system — never has to see those core definitions to work
  # correctly; belt-and-suspenders since core lives outside DGC_SERVICES_ROOT
  # anyway.
  DGC_DEFINITION = /\A\s*def\s/

  # `action_category:` as a bare keyword parameter (`def gated_result
  # (action_category:, ...)`) has no value on that line — the character right
  # after the colon is whitespace then a comma/paren, not an expression.
  DGC_CATEGORY_ARG = /action_category:\s*([^,\s][^,]*?),?\s*\z/

  # A bare lowercase identifier is a local variable / parameter passthrough,
  # not a literal this scan can resolve — and, empirically, the only case of
  # this in the extension is `#gated_result`'s own pass-through parameter,
  # whose real value comes from its callers, each of which supplies a
  # resolvable literal or constant that this same scan finds independently.
  DGC_BARE_PASSTHROUGH = /\A[a-z_][a-zA-Z0-9_]*\z/

  DGC_STRING_LITERAL = /\A"([^"#]*)"\z/
  DGC_INTERPOLATED_PREFIX = /\A"([^"#]*)#\{/
  DGC_CONSTANT_PATH = /\A::?(?:[A-Z]\w*::)+[A-Z][A-Z0-9_]*\z/

  # A bare (unqualified) constant — `REAP_ACTION_CATEGORY`, not
  # `::Sdwan::Executors::X::ACTION_CATEGORY` — resolved by Ruby's lexical
  # scope, which this scan does not reconstruct. Resolved instead by finding
  # `CONST = "literal"` in the SAME FILE, which is how every current instance
  # of this shape is written. A bare constant assigned from anything other
  # than a string literal, or defined in a different file, is out of reach
  # here and reported unresolved rather than guessed.
  DGC_BARE_CONSTANT = /\A[A-Z][A-Z0-9_]*\z/

  DGCDiscoveredSite = Struct.new(:path, :categories, :prefixes, :unresolved, keyword_init: true)

  # THE ATTRIBUTION FIX THIS SPEC EARNED ON ITS FIRST RUN: scanning the whole
  # file for every `action_category:` line, once ANY line in it matched
  # DGC_CALL, over-attributed a class-level `action_category:` DSL keyword —
  # unrelated metadata read by a different chokepoint entirely — to a real
  # `::Ai::AutonomyGate.evaluate(...)` call many lines away in the same file
  # (System::Ai::Skills::ReplaceInstanceExecutor: its skill-declaration
  # `action_category: "system.instance_replace"` at line ~128 got credited to
  # the file's actual direct-gate call at line ~597, which passes a
  # completely different category, REAP_ACTION_CATEGORY /
  # "system.instance_reap"). Attribution is now WINDOWED: only an
  # `action_category:` found within a few lines of an actual matched call is
  # counted for that call. This is why the false "system.instance_replace"
  # overlap this spec first reported is gone — see the coherence describe
  # block below for what a genuine, confirmed overlap
  # (system.sdwan_vip_failover) looks like instead.
  #
  # THE WINDOW IS BOUNDED, NOT JUST CAPPED. A flat "next N lines" window is
  # loud on a MISS (good — an unresolved category fails the spec) but silent
  # on a MIS-ATTRIBUTION: if the call's own args never resolve but some
  # UNRELATED `action_category:` happens to sit within the next N lines
  # (a different call, a different declaration), the first match wins and
  # gets credited to the wrong call site with no error at all. So the window
  # stops at whichever comes first: a line matching
  # `/\A\s*(def|class|module|declare_action)\b/` (a new construct — this
  # call's argument list cannot have continued past it), a non-comment line
  # whose indentation returns to <= the call line's own (Ruby's actual
  # argument-list convention: continuation lines sit deeper than the call
  # that opens them, so returning to or below the call's own indent means
  # the call has closed), or DGC_ARG_WINDOW lines as a hard safety cap.
  # Comment lines never trigger the indentation stop on their own — a
  # same-indent or shallow comment inside a call's argument list is common
  # style (see node_instance_gating.rb's own multi-line comment ahead of its
  # `action_category:` line) and closing a call is not something a comment
  # can do.
  DGC_ARG_WINDOW = 15

  def self.indent_of(line)
    line[/\A[ \t]*/].length
  end

  def self.bounded_window(lines, i)
    call_indent = indent_of(lines[i])
    window = [ lines[i] ]

    ((i + 1)...[ lines.length, i + DGC_ARG_WINDOW ].min).each do |j|
      line = lines[j]
      break if line.match?(/\A\s*(?:def|class|module|declare_action)\b/)
      break if !line.lstrip.start_with?("#") && !line.strip.empty? && indent_of(line) <= call_indent

      window << line
    end

    window
  end

  def self.scan_file(path)
    lines = File.readlines(path)
    call_indexes = lines.each_index.select do |i|
      !lines[i].lstrip.start_with?("#") && lines[i].match?(DGC_CALL)
    end
    return nil if call_indexes.empty?

    categories = []
    prefixes = []
    unresolved = []

    call_indexes.each do |i|
      window = bounded_window(lines, i)
      arg_line = window.find { |l| !l.lstrip.start_with?("#") && !l.match?(DGC_DEFINITION) && l.match?(DGC_CATEGORY_ARG) }

      unless arg_line
        unresolved << "#{path}:#{i + 1}: no action_category: found within #{DGC_ARG_WINDOW} lines of this call"
        next
      end

      expr = arg_line.match(DGC_CATEGORY_ARG)[1].strip
      site = "#{path}:#{i + 1}"

      case expr
      when DGC_STRING_LITERAL then categories << Regexp.last_match(1)
      when DGC_BARE_PASSTHROUGH then next
      else
        if (pm = expr.match(DGC_INTERPOLATED_PREFIX))
          prefixes << pm[1]
        elsif expr.match?(DGC_CONSTANT_PATH)
          begin
            categories << expr.sub(/\A::/, "").constantize
          rescue NameError => e
            unresolved << "#{site}: #{expr.inspect} (#{e.message})"
          end
        elsif expr.match?(DGC_BARE_CONSTANT)
          const_line = lines.find { |l| l.match?(/\A\s*#{Regexp.escape(expr)}\s*=\s*"/) }
          if const_line && (cm = const_line.match(/=\s*"([^"]*)"/))
            categories << cm[1]
          else
            unresolved << "#{site}: #{expr.inspect} (bare constant not assigned a string literal in this file)"
          end
        else
          unresolved << "#{site}: #{expr.inspect}"
        end
      end
    end

    DGCDiscoveredSite.new(path: path, categories: categories.uniq, prefixes: prefixes.uniq, unresolved: unresolved)
  end

  # Rooted at the extension's whole `app/` (not just `app/services`, unlike
  # ActionCategoryRouter's/RoutedLaneGuard's scans) because the direct-gate
  # call sites live in app/controllers and app/services/ai/tools, not only
  # app/services.
  def self.discovered
    Dir.glob(File.join(DGC_SERVICES_ROOT.to_s, "**", "*.rb")).sort
       .filter_map { |path| scan_file(path) }
  end

  DGC_DISCOVERED = discovered.freeze

  describe "structural: resolution has no silent gap" do
    it "finds at least the known direct-gate call sites" do
      relative = DGC_DISCOVERED.map { |d| Pathname.new(d.path).relative_path_from(DGC_SERVICES_ROOT).to_s }

      expect(relative).to include(
        a_string_matching(%r{disk_image_publications_controller\.rb\z}),
        a_string_matching(%r{tasks_controller\.rb\z}),
        a_string_matching(%r{sdwan/peers_controller\.rb\z}),
        a_string_matching(%r{node_instance_gating\.rb\z}),
        a_string_matching(%r{sdwan_tool\.rb\z})
      )
    end

    # A category chosen at runtime from a hash of literals
    # (`GATED_UPDATE_CATEGORIES[:ceiling_raise/:archive].first`) cannot be
    # resolved by this scanner without reimplementing Ruby's hash/array
    # evaluation — out of proportion to the one call site that needs it.
    # Manually verified instead: GATED_UPDATE_CATEGORIES declares
    # "system.instance_pool_ceiling_raise" and "system.instance_pool_archive"
    # (instance_pools_controller.rb:32-34); grepped against
    # System::Fleet::DecisionEngine — neither appears. Allowlisted here, by
    # exact site, so a DIFFERENT unresolved expression still fails loudly.
    DGC_KNOWN_UNRESOLVED = [
      /instance_pools_controller\.rb:\d+: "categories\.first"\z/
    ].freeze

    it "resolves every discovered action_category: argument to a literal, a prefix, or a constant" do
      all_unresolved = DGC_DISCOVERED.flat_map(&:unresolved)
                                     .reject { |u| DGC_KNOWN_UNRESOLVED.any? { |pattern| u.match?(pattern) } }

      expect(all_unresolved).to be_empty, <<~MSG
        A direct Ai::AutonomyGate call site's action_category: could not be
        resolved from source:

          #{all_unresolved.join("\n  ")}

        Either express it as a string literal, an interpolated string with a
        static prefix, or a Klass::CONSTANT path this scanner can constantize
        — or extend DGC_CATEGORY_ARG/the resolver here to understand the new
        shape. An unresolved category is invisible to this coherence check,
        which is exactly the silent gap this spec exists to refuse.
      MSG
    end
  end

  # ACCEPTED, TRACKED GAP — offer 01a0bced-2351-764f-99a3-ef25362279eb.
  #
  # system.sdwan_vip_failover is reachable both through DecisionEngine's
  # routed set (decision_engine.rb:693) and directly via SdwanTool's manual
  # failover (sdwan_tool.rb:2729,
  # ::Sdwan::Executors::FailoverVirtualIp::ACTION_CATEGORY) — deliberately
  # shared (IMP-7c911ca26585: "system.sdwan_vip_failover is shared rather
  # than owned"), so one tuned policy row governs both entry points.
  #
  # WHY ALLOWLISTED RATHER THAN FIXED THIS ROUND: the category IS declared in
  # System::Governance::PolicyDeclarations::SDWAN_REMEDIATION_POLICIES
  # (policy_declarations.rb:765, "require_approval"), and PolicyReconciler is
  # absence-only and runs on EVERY BOOT from rails-start.sh on
  # module-composed hubs (not first-boot-seed only). So the row lands and the
  # block-vs-park divergence closes itself; the exposure is bounded to the
  # window between a declaration merging and the fleet's next reconcile/
  # reboot — real, but self-healing, not a standing gap.
  #
  # SELF-DEFEATING BY DESIGN. This allowlist is valid only as long as its own
  # premise holds: the category stays declared somewhere PolicyReconciler
  # actually consumes. If that declaration is ever removed, the reconciler
  # stops landing the row and the whole basis above evaporates — so the
  # second example below checks the premise directly and reds the allowlist
  # itself the moment it stops being true, rather than silently continuing
  # to excuse a gap that has become unbounded. An allowlist that cannot
  # notice its own premise dying is how a known gap becomes an unknown one.
  #
  # THE PREMISE CHECK IS PINNED ONE HOP FROM THE MECHANISM ON PURPOSE, NOT
  # ON SDWAN_REMEDIATION_POLICIES DIRECTLY. PolicyReconciler#declared_sets
  # consumes `[manual_set] + PolicyDeclarations::POLICY_SETS`
  # (policy_reconciler.rb:412), and SDWAN_REMEDIATION_POLICIES only reaches
  # that because it is merged into SDWAN_MANAGER_POLICIES
  # (policy_declarations.rb:976), which is the `policies:` of the
  # "sdwan-manager" POLICY_SETS entry. Asserting the hash constant directly
  # would go green even if SDWAN_MANAGER_POLICIES stopped including it, or
  # if the "sdwan-manager" entry were dropped from POLICY_SETS entirely —
  # both leave the constant's OWN contents unchanged while the reconciler
  # stops landing the row, which is exactly the unbounded gap this allowlist
  # exists to refuse. Asserting what the reconciler actually consumes closes
  # that: a premise check pinned one hop from the mechanism is the same
  # defect class as a guard verified on the wrong input.
  DGC_ACCEPTED_OVERLAP_CATEGORIES = %w[system.sdwan_vip_failover].freeze

  describe "coherence: no discovered direct-gate category overlaps a routed one" do
    it "shares no exact category with System::Fleet::DecisionEngine.routed_action_categories, " \
       "beyond the accepted, tracked overlap" do
      all_categories = DGC_DISCOVERED.flat_map(&:categories).uniq
      routed = System::Fleet::DecisionEngine.routed_action_categories

      overlap = (all_categories & routed) - DGC_ACCEPTED_OVERLAP_CATEGORIES

      expect(overlap).to be_empty, <<~MSG
        #{overlap.join(', ')} #{overlap.size == 1 ? 'is' : 'are'} reachable both through a
        direct Ai::AutonomyGate call site and through
        System::Fleet::DecisionEngine's routed set. A missing policy row for
        #{overlap.size == 1 ? 'it' : 'them'} BLOCKS loudly (GATE_POLICY_MISSING) on the
        reconcile-tick path and PARKS silently on the direct-gate path — pick
        one behaviour for this category, or rename one side so they are
        actually distinct lanes.
      MSG
    end

    # THE PREMISE CHECK — pinned to what PolicyReconciler#declared_sets
    # ACTUALLY consumes (`[manual_set] + PolicyDeclarations::POLICY_SETS`,
    # policy_reconciler.rb:412), not to SDWAN_REMEDIATION_POLICIES directly.
    # See the comment above DGC_ACCEPTED_OVERLAP_CATEGORIES for why that one
    # hop matters: this must go red if the row would ever stop landing on
    # reconcile, whether that happens by editing the hash constant, by
    # dropping it from SDWAN_MANAGER_POLICIES, or by removing the
    # "sdwan-manager" entry from POLICY_SETS outright.
    it "keeps system.sdwan_vip_failover in what PolicyReconciler actually consumes — the allowlist's own premise" do
      declared = System::Governance::PolicyDeclarations::POLICY_SETS
                 .flat_map { |s| (s[:policies] || {}).to_a }.to_h

      expect(declared).to include("system.sdwan_vip_failover" => "require_approval"),
        "system.sdwan_vip_failover is no longer among the categories " \
        "PolicyReconciler#declared_sets consumes from PolicyDeclarations::POLICY_SETS " \
        "— the coherence spec's allowlist for it " \
        "(offer 01a0bced-2351-764f-99a3-ef25362279eb) assumed PolicyReconciler " \
        "keeps landing this row every boot BECAUSE it stays declared there. That " \
        "basis just broke: either restore the declaration (directly, via " \
        "SDWAN_MANAGER_POLICIES, or via the sdwan-manager POLICY_SETS entry), or " \
        "remove system.sdwan_vip_failover from DGC_ACCEPTED_OVERLAP_CATEGORIES and " \
        "let the overlap assertion above refuse it for real."
    end

    it "shares no routed category with a static prefix a direct-gate call site interpolates into" do
      all_prefixes = DGC_DISCOVERED.flat_map(&:prefixes).uniq
      routed = System::Fleet::DecisionEngine.routed_action_categories

      collisions = all_prefixes.flat_map { |prefix| routed.select { |r| r.start_with?(prefix) } }

      expect(collisions).to be_empty, <<~MSG
        #{collisions.join(', ')} #{collisions.size == 1 ? 'is' : 'are'} routed by DecisionEngine and also
        #{collisions.size == 1 ? 'falls' : 'fall'} under an interpolated action_category prefix
        (#{all_prefixes.join(', ')}) a direct-gate call site builds at runtime
        — same block-vs-park defect, just not visible as an exact-string match.
      MSG
    end

    # Positive control: today's known interpolated-category call sites
    # (tasks_controller.rb, node_instance_gating.rb) really do build
    # "system.task.<verb>", so the prefix scan above is exercising a real
    # value, not an empty set that would pass vacuously.
    it "actually discovered the system.task. prefix (premise check for the prefix assertion above)" do
      expect(DGC_DISCOVERED.flat_map(&:prefixes)).to include("system.task.")
    end

    # Positive control for the exact-match assertion: today's known
    # constant-resolved categories really do resolve to non-empty strings.
    it "actually discovered sdwan.peer_delete and sdwan.peer_update (premise check)" do
      expect(DGC_DISCOVERED.flat_map(&:categories)).to include("sdwan.peer_delete", "sdwan.peer_update")
    end
  end
end
