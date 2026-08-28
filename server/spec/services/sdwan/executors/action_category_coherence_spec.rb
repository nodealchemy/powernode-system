# frozen_string_literal: true

require "rails_helper"
require "ripper"
require "tempfile"

# IMP-249e01a804e5 — the autonomy action_category strings for SDWAN had no
# single source of truth. They existed as Ruby constants on Ai::Tools::SdwanTool
# and as BARE STRING LITERALS at all 26 REST gate sites, while the executor that
# actually owns each action declared nothing at all. Folding or renaming a
# category was therefore a hand-edit across 7+ sites in 2+ files, with typo
# protection only inside the tool.
#
# The fix makes the EXECUTOR the declaration site (Sdwan::Executors::X::
# ACTION_CATEGORY) and both gating surfaces reference it. This file is the
# coherence guard for the surfaces a constant reference cannot reach.
#
# Modelled on spec/lib/powernode_system/autonomy_categories_registration_spec.rb
# — the same SUBSET invariant, one link further up the chain:
#
#     declared ⊆ registered      (an operator can retune every declared action)
#     declared ⊆ seeded          (every declared action has a policy row)
#     every gate site's category IS its executor's declaration
#
# Subset, not equality, in both directions that matter: a category may be
# seeded and registered before any executor claims it, and that is fine — the
# invariant this file protects is that nothing an executor OWNS can drift away
# from the surfaces that gate and tune it. (`sdwan.access_grant_create` was the
# standing example until IMP-343163bf37a4 gave it an executor and gate sites on
# both surfaces; the subset direction is what let it be seeded that whole time
# while nothing evaluated it.)
#
# One deliberate consequence, since the refactor is otherwise behaviour-free:
# a gate site now RESOLVES its executor class where it used to pass the class
# name as an inert string (Ai::AutonomyGate never constantizes it on the
# :pending branch). A gate site naming an executor that does not exist now
# raises NameError at the gate instead of at approval-time execution. That is
# the better failure — it is unreachable in a green tree, and reachable only in
# exactly the tree this file exists to prevent.
RSpec.describe "SDWAN executor action categories", type: :lib do
  # `let`, not constants: a bare constant assigned inside a describe block lands
  # on Object, and a generic name there is the duplicate-constant clobber that
  # makes suites order-dependent.
  let(:ext_server_root) { Pathname.new(File.expand_path("../../../..", __dir__)) }
  let(:executor_dir)    { ext_server_root.join("app/services/sdwan/executors") }
  let(:seed_dir)        { ext_server_root.join("db/seeds") }

  # BOTH gating surfaces. Globbed rather than listed so a new SDWAN controller
  # is in scope the day it lands.
  let(:gate_source_paths) do
    controllers = Dir[ext_server_root.join("app/controllers/api/v1/system/sdwan/*.rb").to_s].sort
    tool        = ext_server_root.join("app/services/ai/tools/sdwan_tool.rb").to_s
    raise "no SDWAN controllers found under #{ext_server_root}" if controllers.empty?
    raise "SDWAN MCP tool not found at #{tool}"                unless File.exist?(tool)

    controllers + [ tool ]
  end

  # Directory-driven: a NEW executor is automatically held to the invariant.
  let(:executor_classes) do
    files = Dir[executor_dir.join("*.rb").to_s].sort
    raise "no SDWAN executors found at #{executor_dir}" if files.empty?

    files.map { |f| "Sdwan::Executors::#{File.basename(f, '.rb').camelize}".constantize }
  end

  # `inherit: false` deliberately — the point is that the EXECUTOR declares it,
  # not that something up the ancestry chain happens to answer.
  let(:declared) do
    executor_classes.select { |k| k.const_defined?(:ACTION_CATEGORY, false) }
                    .to_h { |k| [ k.name, k.const_get(:ACTION_CATEGORY, false) ] }
  end

  # A seed entry is a `"category" => "policy"` pair; anchoring the RHS to
  # Ai::InterventionPolicy::POLICIES keeps this from matching arbitrary
  # string-to-string hashes elsewhere in the seed files.
  let(:seed_entry_pattern) do
    /"([a-z][a-z0-9_.]*)"\s*=>\s*"(?:#{Ai::InterventionPolicy::POLICIES.join('|')})"/
  end

  # Categories the code DECLARES. The agent and operator policy sets moved out
  # of the seed files into System::Governance::PolicyDeclarations so the boot
  # reconciler could assert them against a running database — which put them
  # beyond the reach of the literal scan below. Reading the constants cannot be
  # defeated by reformatting; the scan is KEPT for the seed files that still
  # carry their own literals.
  let(:declared_policy_categories) do
    d = System::Governance::PolicyDeclarations
    ([ d::MANUAL_OPERATION_POLICIES ] + d::POLICY_SETS.map { |set| set[:policies] })
      .flat_map(&:keys)
  end

  let(:scanned_seed_categories) do
    Dir[seed_dir.join("*.rb").to_s].sort
       .flat_map { |f| File.read(f).scan(seed_entry_pattern).flatten }
  end

  let(:seeded_categories) do
    (declared_policy_categories + scanned_seed_categories).uniq
  end

  # Every `action_category:` argument in the gating surfaces, paired with the
  # `executor_class:` it is passed alongside.
  #
  # LEXED with Ripper rather than grepped, because a text scan cannot tell a
  # live argument from a commented-out one — a guard that passes when the line
  # is commented out is not a guard. Ripper drops :on_comment tokens, so only
  # executable arguments are read.
  #
  # A site is recognised as a GATE by what sits next to it — a gate call always
  # names its executor with a string literal — and NEVER by the shape of the
  # action_category value, because the value shapes a drifting site would use
  # are exactly the ones a shape-first classifier mistakes for plumbing:
  # `action_category:` (Ruby 3.1 shorthand) lexes as no value at all, and a
  # hoisted `action_category: cat` lexes as a bare local. Both are live gate
  # sites carrying a hand-written string, and both would be skipped in silence.
  # So the pairing lookup runs FIRST and decides.
  #
  # Only then is the leftover classified, and TOTALLY — the two plumbing shapes
  # are enumerated and anything else RAISES. Both plumbing shapes are real:
  # SdwanTool's own `gated_result` helper DECLARES the keyword
  # (`def gated_result(action_category:, executor_class:, …)`) and FORWARDS it
  # into the MCP response payload (`action_category: action_category`), and the
  # declaration sits next to an `executor_class:` of its own — which is why the
  # pairing test is "an executor_class whose value is a STRING", not merely
  # "an executor_class".
  def gate_sites(path)
    tokens = Ripper.lex(File.read(path))
                   .reject { |(_pos, type, _tok, _state)| %i[on_sp on_comment on_nl on_ignored_nl].include?(type) }

    sites = []
    tokens.each_with_index do |(pos, type, tok, _state), idx|
      next unless type == :on_label && tok == "action_category:"

      value_tokens = []
      j = idx + 1
      while j < tokens.size && !%i[on_comma on_rparen].include?(tokens[j][1])
        value_tokens << tokens[j]
        j += 1
      end

      exec_class, exec_line = executor_argument(tokens, j)

      if exec_class.nil?
        shapes = value_tokens.map { |t| t[1] }.uniq
        next if value_tokens.empty?     # `def gated_result(action_category:, …)`
        next if shapes == [ :on_ident ] # `action_category: action_category`

        raise "#{File.basename(path)}:#{pos[0]} passes action_category: with no adjacent executor_class: " \
              "string, in a shape this guard does not classify as plumbing (#{shapes.inspect}) — it would " \
              "be skipped silently, so the guard must be taught it"
      end

      if (exec_line - pos[0]) > 3
        raise "#{File.basename(path)}:#{pos[0]} is #{exec_line - pos[0]} lines from its executor_class: — " \
              "the adjacency this guard pairs on no longer holds, so it would certify the wrong pair"
      end

      sites << {
        file: File.basename(path), line: pos[0],
        category_source: value_tokens.map { |t| t[2] }.join, executor_class: exec_class
      }
    end
    sites
  end

  # The `executor_class: "..."` of the SAME call, or nil. Depth-tracked so it
  # cannot reach out of the call it started in and borrow a neighbour's
  # executor_class — without that, a call passing action_category and no
  # executor at all is certified by whatever call happens to follow it.
  # Returns nil for a non-literal executor_class, which is what distinguishes
  # `gated_result`'s own declaration and forwarding from a real gate call.
  def executor_argument(tokens, start)
    depth = 0
    k = start
    while k < tokens.size
      type = tokens[k][1]
      depth += 1 if %i[on_lparen on_lbracket on_lbrace on_embexpr_beg].include?(type)
      if %i[on_rparen on_rbracket on_rbrace on_embexpr_end].include?(type)
        return [ nil, nil ] if depth.zero? # left the call

        depth -= 1
      end

      if depth.zero? && type == :on_label && tokens[k][2] == "executor_class:"
        return [ nil, nil ] unless tokens[k + 1] && tokens[k + 1][1] == :on_tstring_beg

        name = +""
        m = k + 1
        while m < tokens.size && !%i[on_comma on_rparen].include?(tokens[m][1])
          name << tokens[m][2] if tokens[m][1] == :on_tstring_content
          m += 1
        end
        return name.empty? ? [ nil, nil ] : [ name, tokens[k][0][0] ]
      end
      k += 1
    end
    [ nil, nil ]
  end

  let(:all_gate_sites) { gate_source_paths.flat_map { |p| gate_sites(p) } }

  it "declares ACTION_CATEGORY on every SDWAN executor" do
    missing = executor_classes.reject { |k| k.const_defined?(:ACTION_CATEGORY, false) }.map(&:name)

    expect(missing).to be_empty,
                       "#{missing.size} SDWAN executor(s) own an autonomy action but declare no ACTION_CATEGORY, " \
                       "so their category has no single source of truth and every gating surface must " \
                       "hand-carry the string: #{missing.join(', ')}"
  end

  # Sharing is PINNED, not forbidden. Two executors under one category resolve
  # to ONE intervention policy row, which is a copy-paste bug when a new
  # executor inherits its neighbour's string — and is the intended result when
  # categories are deliberately CONSOLIDATED (folding firewall_rule_update into
  # a broader manage category is the example the finding itself names). A
  # blanket uniqueness rule would red on the very operation this refactor
  # exists to make cheap, so the list records intent instead: a consolidation
  # is a one-line edit here that says so, an accident is a red with no line to
  # write. Empty today — no two SDWAN executors share a category.
  it "shares a category between executors only where that is recorded" do
    deliberately_shared = {}

    shared = declared.group_by { |_klass, cat| cat }
                     .select { |_cat, pairs| pairs.size > 1 }
                     .transform_values { |pairs| pairs.map(&:first).sort }

    expect(shared).to eq(deliberately_shared),
                      "the set of action_categories shared by more than one executor changed. Executors under " \
                      "one category resolve to ONE policy row, so an operator tuning either tunes both: " \
                      "#{shared.inspect}"
  end

  # Implied TODAY by `declared ⊆ seeded` above and `seeded ⊆ registered` in
  # spec/lib/powernode_system/autonomy_categories_registration_spec.rb, so it
  # cannot red while both of those hold. Kept because it reads the RUNTIME
  # registry rather than the seed sources: when the seed scan is what broke,
  # this example is the one that still names engine.rb as the fix.
  it "registers every declared category so an operator can retune it" do
    missing = declared.values.uniq.reject { |cat| Ai::InterventionPolicy.category_registered?(cat) }

    expect(missing).to be_empty,
                       "#{missing.size} executor-declared category(ies) are absent from the engine's registry " \
                       "(lib/powernode_system/engine.rb), so PATCH /api/v1/system/autonomy rejects every " \
                       "operator edit to them: #{missing.join(', ')}"
  end

  it "seeds an intervention policy for every declared category" do
    orphans = declared.reject { |_klass, cat| seeded_categories.include?(cat) }

    expect(orphans).to be_empty,
                       "executor(s) declare a category no seed file creates a policy row for, so the action " \
                       "resolves to the default policy instead of its recorded intent — rename the seed key " \
                       "to match, or the declaration: #{orphans.inspect}"
  end

  # IMP-051f3811ac60 — the REVERSE direction of the gate-site scan. An
  # executor no gate site names is not "dormant infrastructure": its seeded
  # policy row reads as a control that exists while nothing ever evaluates it.
  # sdwan.network_create and sdwan.user_device_create shipped exactly that way
  # — and CreateUserDevice's never-called body was additionally WRONG (a bare
  # create! bypassing UserDeviceIssuer), with deadness the only reason nobody
  # noticed. Composition-only dispatch is legitimate but must be RECORDED, not
  # inferred: a `.execute(` reference somewhere in app/ proves a Ruby call,
  # not that the operator's policy for the category has an evaluation site.
  it "names every executor at at least one gate site, or records it as composition-only" do
    # Executors deliberately dispatched ONLY by internal composition (never an
    # operator gate site). Empty today; adding a name here is the recorded
    # intent, the way deliberately_shared records category consolidation.
    composition_only = []

    named   = all_gate_sites.map { |site| site[:executor_class] }.uniq
    unnamed = executor_classes.map(&:name) - named - composition_only

    expect(unnamed).to be_empty,
                       "#{unnamed.size} SDWAN executor(s) are named by NO gate site on either operator " \
                       "surface, so their declared category is seeded and registered but never evaluated: " \
                       "#{unnamed.join(', ')} — wire a gate site, or record the executor in " \
                       "composition_only above"
  end

  it "passes each gate site its executor's declared ACTION_CATEGORY, never a literal" do
    offenders = all_gate_sites.reject do |site|
      site[:category_source] == "::#{site[:executor_class]}::ACTION_CATEGORY"
    end

    expect(offenders).to be_empty,
                         "#{offenders.size} SDWAN gate site(s) do not read their executor's declaration, so a " \
                         "category rename silently forks the two surfaces: " \
                         "#{offenders.map { |o| "#{o[:file]}:#{o[:line]} passes #{o[:category_source]} to #{o[:executor_class]}" }.join('; ')}"
  end

  # The scanner's OWN oracle. Everything above trusts gate_sites to find the
  # drift, and a scanner that quietly returns nothing is indistinguishable from
  # a clean tree — the count floor below catches that only for sites that
  # already exist, never for a NEW one written in a shape the scan walks past.
  # So each shape a drifting site could plausibly take is exercised against
  # constructed source, together with the plumbing that must still be ignored.
  #
  # Refusals paired with positive controls throughout: over-tightening this
  # scan (classifying a real gate call as plumbing) is invisible to a
  # refusal-only test, and is the exact failure the first two cases pin.
  it "reports a drifting gate site whatever shape its value takes, and invents none" do
    scan = lambda do |source|
      Tempfile.create([ "gate_scan", ".rb" ]) do |f|
        f.write(source)
        f.flush
        gate_sites(f.path)
      end
    end

    conforming = scan.call(<<~RUBY)
      gate!(
        action_category: ::Sdwan::Executors::DeleteNetwork::ACTION_CATEGORY,
        executor_class: "Sdwan::Executors::DeleteNetwork"
      )
    RUBY
    expect(conforming.map { |s| s[:category_source] }).to eq([ "::Sdwan::Executors::DeleteNetwork::ACTION_CATEGORY" ])

    # The three drifting shapes. A bare literal is the regression itself; the
    # other two are what a shape-first classifier mistakes for plumbing —
    # Ruby 3.1 hash shorthand lexes as NO value, a hoisted local as a bare
    # ident, and both carry a hand-written string at a live gate call.
    %w[
      "sdwan.network_delete"
      cat
    ].each do |drift|
      sites = scan.call(<<~RUBY)
        gate!(
          action_category: #{drift},
          executor_class: "Sdwan::Executors::DeleteNetwork"
        )
      RUBY
      expect(sites.map { |s| s[:category_source] }).to eq([ drift ]), "shape #{drift.inspect} was not reported"
    end

    shorthand = scan.call(<<~RUBY)
      gate!(
        action_category:,
        executor_class: "Sdwan::Executors::DeleteNetwork"
      )
    RUBY
    expect(shorthand.map { |s| s[:category_source] }).to eq([ "" ])

    # Plumbing that must stay ignored — both shapes are live in SdwanTool.
    expect(scan.call(<<~RUBY)).to be_empty
      def gated_result(action_category:, executor_class:, executor_params:)
      end
    RUBY
    expect(scan.call(<<~RUBY)).to be_empty
      success_result(action_category: action_category, executor_class: executor_class)
    RUBY

    # And it may not reach out of the call it started in to borrow a
    # neighbour's executor_class, which would certify a pairing nobody wrote.
    expect { scan.call(<<~RUBY) }.to raise_error(/no adjacent executor_class/)
      audit_only(action_category: ::Sdwan::Executors::DeletePeer::ACTION_CATEGORY, skill: "x")
      other_call(executor_class: "Sdwan::Executors::DeletePeer")
    RUBY
  end

  # Cross-surface pin the constant reference itself cannot make.
  #
  # System::Fleet::DecisionEngine::SIGNAL_BINDINGS keeps its literal for a
  # vocabulary reason, not a load-order one — it already names extension
  # classes in its own class body (`skill: ::System::Ai::Skills::…`), so a
  # constant reference would load fine. Its keys are the SENSOR remediation
  # namespace, and system.sdwan_vip_failover is the single entry in it that any
  # executor also owns; referencing the executor for that one row and literals
  # for its dozen neighbours would read as a distinction that isn't there.
  #
  # So the literal stays and this example is what reds when the executor
  # renames out from under it — a silent drift that would otherwise route the
  # SdwanVipReachabilitySensor's remediation at a category with no policy row.
  it "binds the VIP-failover sensor to the executor's declared category" do
    binding = System::Fleet::DecisionEngine::SIGNAL_BINDINGS.fetch("system.sdwan_vip_unreachable")

    expect(binding[:action_category]).to eq(Sdwan::Executors::FailoverVirtualIp::ACTION_CATEGORY)
  end

  # Vacuity guard. Every example above is a "reject the bad ones" shape, which
  # an empty input satisfies perfectly — a moved executor directory, a renamed
  # seed dir, a reformatted gate call the lexer walks past, and all five go
  # green while protecting nothing. These floors are the current counts, so no
  # addition of mine can satisfy them by accident.
  it "reads real inputs on every surface it claims to guard" do
    expect(executor_classes.size).to be >= 43
    expect(declared.size).to eq(executor_classes.size)
    expect(seeded_categories.size).to be > 50
    # The declared half separately: the union staying above the floor would
    # otherwise hide it collapsing to nothing, which is exactly what moving the
    # hashes into constants did to the scan.
    expect(declared_policy_categories.size).to be > 50
    expect(all_gate_sites.size).to be >= 61
    expect(all_gate_sites.map { |s| s[:file] }.uniq.size).to be >= 9
    expect(Ai::InterventionPolicy.registered_categories).to include("sdwan.network_create")
  end
end
