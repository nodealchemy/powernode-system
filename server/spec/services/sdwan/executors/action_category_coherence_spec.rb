# frozen_string_literal: true

require "rails_helper"
require "ripper"

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
# Subset, not equality, in both directions that matter: `sdwan.access_grant_create`
# is seeded and registered but has no executor class, and that is fine — the
# invariant this file protects is that nothing an executor OWNS can drift away
# from the surfaces that gate and tune it.
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

  let(:seeded_categories) do
    Dir[seed_dir.join("*.rb").to_s].sort
       .flat_map { |f| File.read(f).scan(seed_entry_pattern).flatten }
       .uniq
  end

  # Every `action_category:` argument in the gating surfaces, paired with the
  # `executor_class:` it is passed alongside.
  #
  # LEXED with Ripper rather than grepped, because a text scan cannot tell a
  # live argument from a commented-out one — a guard that passes when the line
  # is commented out is not a guard. Ripper drops :on_comment tokens, so only
  # executable arguments are read.
  #
  # Classification is TOTAL: every `action_category:` label in these files is
  # sorted into one of three shapes and an unrecognised one RAISES. A scan that
  # silently skipped what it did not understand is the failure mode that would
  # let this whole file pass while reading nothing — and there is a live example
  # of exactly that here, because SdwanTool's own `gated_result` helper both
  # DECLARES the keyword and FORWARDS it into the MCP response payload:
  #
  #   :declaration — `def gated_result(action_category:, …)`, no value at all
  #   :forwarding  — `action_category: action_category`, a bare local
  #   :gate        — a literal or constant, and the only shape this file gates on
  #
  # The pairing rule (`the executor_class: label that follows within 3 lines`)
  # is the shape every gate call in this codebase has, and it too is asserted
  # rather than assumed.
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

      shapes = value_tokens.map { |t| t[1] }.uniq
      next if value_tokens.empty?          # :declaration — a `def` keyword arg
      next if shapes == [ :on_ident ]      # :forwarding  — a bare local

      unless (shapes - %i[on_const on_op]).empty? || shapes.first == :on_tstring_beg
        raise "#{File.basename(path)}:#{pos[0]} passes action_category: in a shape this guard does not " \
              "classify (#{shapes.inspect}) — it would be skipped silently, so the guard must be taught it"
      end

      exec_class = nil
      exec_line  = nil
      k = j
      while k < tokens.size
        if tokens[k][1] == :on_label && tokens[k][2] == "executor_class:"
          exec_line = tokens[k][0][0]
          exec_class = +""
          m = k + 1
          while m < tokens.size && !%i[on_comma on_rparen].include?(tokens[m][1])
            exec_class << tokens[m][2] if tokens[m][1] == :on_tstring_content
            m += 1
          end
          break
        end
        k += 1
      end

      if exec_class.nil? || exec_class.empty? || (exec_line - pos[0]) > 3
        raise "#{File.basename(path)}:#{pos[0]} gates on an action_category with no adjacent executor_class: " \
              "string — the pairing this guard reads no longer holds, so it would certify nothing"
      end

      sites << {
        file: File.basename(path), line: pos[0],
        category_source: value_tokens.map { |t| t[2] }.join, executor_class: exec_class
      }
    end
    sites
  end

  let(:all_gate_sites) { gate_source_paths.flat_map { |p| gate_sites(p) } }

  it "declares ACTION_CATEGORY on every SDWAN executor" do
    missing = executor_classes.reject { |k| k.const_defined?(:ACTION_CATEGORY, false) }.map(&:name)

    expect(missing).to be_empty,
                       "#{missing.size} SDWAN executor(s) own an autonomy action but declare no ACTION_CATEGORY, " \
                       "so their category has no single source of truth and every gating surface must " \
                       "hand-carry the string: #{missing.join(', ')}"
  end

  it "gives each executor its own category" do
    shared = declared.group_by { |_klass, cat| cat }
                     .select { |_cat, pairs| pairs.size > 1 }
                     .transform_values { |pairs| pairs.map(&:first) }

    expect(shared).to be_empty,
                      "executors sharing one action_category resolve to ONE intervention policy row, so an " \
                      "operator tuning either tunes both: #{shared.inspect}"
  end

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

  it "passes each gate site its executor's declared ACTION_CATEGORY, never a literal" do
    offenders = all_gate_sites.reject do |site|
      site[:category_source] == "::#{site[:executor_class]}::ACTION_CATEGORY"
    end

    expect(offenders).to be_empty,
                         "#{offenders.size} SDWAN gate site(s) do not read their executor's declaration, so a " \
                         "category rename silently forks the two surfaces: " \
                         "#{offenders.map { |o| "#{o[:file]}:#{o[:line]} passes #{o[:category_source]} to #{o[:executor_class]}" }.join('; ')}"
  end

  # Cross-surface pin the constant reference itself cannot make.
  # System::Fleet::DecisionEngine::SIGNAL_BINDINGS is a class-body hash, so
  # referencing the executor constant there would autoload an extension class
  # while the engine's own class body is still loading. The literal stays; this
  # example is what reds when the executor renames out from under it — a silent
  # drift that would otherwise route the SdwanVipReachabilitySensor's
  # remediation at a category with no policy row.
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
    expect(executor_classes.size).to be >= 26
    expect(declared.size).to eq(executor_classes.size)
    expect(seeded_categories.size).to be > 50
    expect(all_gate_sites.size).to be >= 42
    expect(all_gate_sites.map { |s| s[:file] }.uniq.size).to be >= 9
    expect(Ai::InterventionPolicy.registered_categories).to include("sdwan.network_create")
  end
end
