# frozen_string_literal: true

require "rails_helper"

# IMP-b400ec1a2df8 — the MISCONFIGURED-LANE refusal is ONE seam, and every
# gate_action! in this extension must reach it.
#
# THE DEFECT THIS EXISTS FOR
#
# IMP-5a450411d873 split the `not permitted` arm in two: a lane the platform
# ROUTES signals to but the database has no policy row for is a DEPLOY DEFECT
# (db:seed is first-boot-only, so a policy added to a seed afterwards never
# reaches an already-running host), while an arbitrary unknown category is an
# ordinary refusal. That fix was written INTO FleetAutonomyService#gate_action!.
#
# There are TWO interchangeable gates. System::CveOps::CveResponderService
# declares itself "Same shape as FleetAutonomyService#gate_action! so
# DecisionEngine can call either interchangeably", runs the CVE sensors on its
# own tick, and gates the two CVE lanes DecisionEngine routes
# (system.cve_remediate, system.module_critical_upgrade_ready). It kept the
# pre-fix shape: a WARN nobody greps and a null `gate` nothing can query. Any
# install whose system_cve_responder_agent seed rows never landed had its
# critical-CVE remediation lane dead in exactly the way IMP-5a450411d873 was
# raised to end — and nothing said so.
#
# WHY THIS SPEC IS SHAPED THE WAY IT IS
#
# Copying the fixed arm into the second service would satisfy today's finding
# and guarantee the same drift the moment a third domain agent appears. So the
# refusal now lives in System::Autonomy::RoutedLaneGuard and both services
# include it — and this spec defends the SEAM, not the copy:
#
#   1. DISCOVERY, not a hand-written list. The gate_action! implementations are
#      found by scanning this extension's own service tree, so a third twin
#      appears here whether or not its author knew this file existed.
#   2. Every discovered implementation must INCLUDE the seam, and must resolve
#      GATE_POLICY_MISSING FROM the seam — the first ancestor defining it has to
#      be RoutedLaneGuard itself. That closes the gap the include check alone
#      leaves open: a twin that includes the seam, shadows the constant, and
#      hand-rolls its own arm. (Do NOT weaken this back to an object-identity
#      check. Frozen string literals are interned globally, so a copied
#      `GATE_POLICY_MISSING = "policy_missing"` in a pragma-carrying file — and
#      the pragma is hook-enforced repo-wide — is the SAME object and passes.)
#   3. Every discovered implementation must be EXERCISED end-to-end below. A
#      class that is discovered but absent from RLG_GATE_IMPLEMENTATIONS fails the
#      registry example, so a new twin cannot be added without wiring it in.
#   4. The behavioural examples call the REAL service's REAL gate_action! with
#      a routed category that has no policy row. Asserting the module in
#      isolation would prove nothing about whether either caller reaches it —
#      the two arms are similar enough that a half-finished refactor passes a
#      module-only test while one caller still takes its own local path.
RSpec.describe System::Autonomy::RoutedLaneGuard do
  # The scan is deliberately bounded to THIS extension. extensions/private/*
  # carries its own gate_action! (Trading::OverseerAutonomyService) with a
  # different arity and its own DecisionEngine-less lifecycle; reaching across
  # the extension boundary here would both couple two self-contained extensions
  # and fail in any clone that has no private extensions at all.
  RLG_SERVICES_ROOT = Rails.root.join("../extensions/system/server/app/services").cleanpath

  # `def gate_action!` is a DEFINITION, so unlike a reference grep it cannot be
  # dodged by a composed or interpolated identifier — except through
  # define_method, which is matched too.
  RLG_GATE_DEFINITION = /^\s*(?:def\s+gate_action!|define_method\s*[(\s]\s*[:"']gate_action!)/

  # Registry of every gate_action! implementation, with what it takes to drive
  # it end-to-end. Discovery above is the authority on membership; this only
  # says HOW to exercise what discovery found.
  RLG_GATE_IMPLEMENTATIONS = {
    "System::Fleet::FleetAutonomyService" => {
      agent_name: "Fleet Autonomy",
      log_tag: "FleetAutonomy",
      # Routed by DecisionEngine::SIGNAL_BINDINGS, gated by the fleet tick.
      routed_category: "system.cert_rotate"
    },
    "System::CveOps::CveResponderService" => {
      agent_name: "CVE Responder",
      log_tag: "CveResponder",
      # Routed by DecisionEngine::SIGNAL_BINDINGS, gated by the CVE tick — the
      # lane this offer was raised about.
      routed_category: "system.cve_remediate"
    }
  }.freeze

  def self.discovered_gate_classes
    Dir.glob(File.join(RLG_SERVICES_ROOT.to_s, "**", "*.rb")).sort.filter_map do |path|
      next unless File.read(path).match?(RLG_GATE_DEFINITION)

      Pathname.new(path).relative_path_from(RLG_SERVICES_ROOT).to_s.delete_suffix(".rb").camelize
    end
  end

  RLG_DISCOVERED = discovered_gate_classes.freeze

  let(:account) { create(:account) }

  describe "structural: the seam cannot be bypassed by a new gate_action!" do
    it "finds at least the two known interchangeable gates" do
      expect(RLG_DISCOVERED).to include(
        "System::Fleet::FleetAutonomyService",
        "System::CveOps::CveResponderService"
      )
    end

    it "exercises EVERY discovered gate_action! implementation" do
      expect(RLG_DISCOVERED).to match_array(RLG_GATE_IMPLEMENTATIONS.keys), <<~MSG
        A gate_action! implementation in extensions/system was found that this spec
        does not drive end-to-end:

          #{(RLG_DISCOVERED - RLG_GATE_IMPLEMENTATIONS.keys).join("\n  ")}

        Every gate that can refuse an action must distinguish a routed-but-unseeded
        lane (a deploy defect) from an ordinary refusal, or that lane dies silently.
        Add it to RLG_GATE_IMPLEMENTATIONS so the examples below actually gate it.
      MSG
    end

    RLG_DISCOVERED.each do |class_name|
      context class_name do
        let(:klass) { class_name.constantize }

        it "includes the shared routed-lane seam" do
          expect(klass.include?(described_class)).to be(true),
            "#{class_name} defines gate_action! but does not include " \
            "System::Autonomy::RoutedLaneGuard — it will refuse routed lanes silently"
        end

        # PROVENANCE, not value — and specifically not object identity.
        #
        # This assertion used to be `equal(described_class::GATE_POLICY_MISSING)`
        # on the theory that a copy-pasted `GATE_POLICY_MISSING = "policy_missing"`
        # would be a different object. It is not. Ruby interns frozen string
        # literals in a GLOBAL fstring table, so two `# frozen_string_literal: true`
        # files each writing "policy_missing" share one object (verified on Ruby
        # 3.2.8: equal? => true, identical object_id). And the pragma is mandatory
        # here — .claude/hooks/ruby-syntax-check.sh and scripts/pattern-validation.sh
        # enforce it repo-wide — so a copy in any NEW twin is guaranteed to be
        # interned and guaranteed to pass. The old assertion could only fail for a
        # twin that OMITTED the pragma, i.e. the one case the hooks already
        # prevent: exactly inverted from its purpose.
        #
        # So ask where the constant COMES FROM. `klass::GATE_POLICY_MISSING`
        # resolves to the first ancestor that defines it directly, so that
        # ancestor must be the seam itself.
        #
        # Chosen over `klass.constants(false)` (blind to a shadow declared in an
        # intermediate module, seeing only class-local ones) and over
        # `const_source_location` (correct, but couples the spec to a file path
        # that a future move would break). This models Ruby's actual lookup order,
        # catches a shadow anywhere in the chain, and is path-independent.
        it "resolves GATE_POLICY_MISSING from the seam, not a local or intermediate copy" do
          definer = klass.ancestors.find { |m| m.const_defined?(:GATE_POLICY_MISSING, false) }

          expect(definer).to eq(described_class),
            "#{class_name}::GATE_POLICY_MISSING resolves from #{definer.inspect}, not " \
            "System::Autonomy::RoutedLaneGuard. A twin that includes the seam but shadows " \
            "the constant can hand-roll its own refusal arm and still pass the include check."
        end
      end
    end
  end

  describe "behavioural: each REAL service refuses a routed-but-unseeded lane through the seam" do
    RLG_GATE_IMPLEMENTATIONS.each do |class_name, config|
      context class_name do
        let(:service) do
          agent = create(:ai_agent, account: account, agent_type: "monitor", name: config[:agent_name])
          class_name.constantize.new(account: account, agent: agent)
        end

        before { allow(Rails.logger).to receive(:error) }

        it "is a category DecisionEngine actually routes" do
          expect(System::Fleet::DecisionEngine.routed_action_categories)
            .to include(config[:routed_category])
        end

        it "blocks a routed lane with no policy row as GATE_POLICY_MISSING" do
          result = service.gate_action!(config[:routed_category])

          # STILL BLOCKS. The fail-safe direction is correct — the defect was
          # the silence. A refusal that let an unseeded lane PROCEED would turn
          # a dormant remediation lane into an ungated one.
          expect(result[:decision]).to eq(:blocked)
          expect(result[:gate]).to eq(described_class::GATE_POLICY_MISSING)
          expect(result[:reason]).to eq(described_class::GATE_POLICY_MISSING)
        end

        it "logs the misconfiguration at ERROR level with its own service tag" do
          service.gate_action!(config[:routed_category])

          expect(Rails.logger).to have_received(:error).with(
            /\[#{Regexp.escape(config[:log_tag])}\] MISCONFIGURED LANE: '#{Regexp.escape(config[:routed_category])}'/
          )
        end

        it "names the agent that is missing the row" do
          service.gate_action!(config[:routed_category])

          expect(Rails.logger).to have_received(:error)
            .with(/agent '#{Regexp.escape(config[:agent_name])}'/)
        end

        # A category nothing routes to is an operator-visible non-event, not a
        # deploy defect. Conflating them would make the new alarm fire on every
        # stray string and train operators to ignore it.
        it "still reports an UNROUTED category as plain not_permitted" do
          result = service.gate_action!("system.definitely_not_a_routed_category")

          expect(result[:decision]).to eq(:blocked)
          expect(result[:reason]).to eq("not_permitted")
          expect(result[:gate]).to be_nil
          # Scoped to the misconfiguration alarm rather than :error wholesale —
          # unrelated framework error lines share this logger.
          expect(Rails.logger).not_to have_received(:error).with(/MISCONFIGURED LANE/)
        end

        # Fail-safe in the OTHER direction: a seeded row must still be reachable,
        # so the seam cannot be satisfied by refusing everything.
        it "does not intercept a lane that DOES have a policy row" do
          Ai::InterventionPolicy.create!(
            account: account, ai_agent_id: service.agent.id, scope: "agent",
            action_category: config[:routed_category],
            policy: "block", is_active: true
          )

          result = service.gate_action!(config[:routed_category])

          expect(result[:gate]).to eq("block")
          expect(result[:gate]).not_to eq(described_class::GATE_POLICY_MISSING)
        end

        # THE SEAM'S REACHABILITY, not the seam itself.
        #
        # `permitted_actions` is the PRE-GATE: it decides whether
        # refuse_unpermitted_action runs at all. The fundamental system agents
        # are seeded GLOBAL (account_id nil, one shared row) while their POLICY
        # rows are per-account, so every tenant's rows hang off the same
        # ai_agent_id. A pre-gate that forgets the account filter therefore
        # answers from every tenant at once — and because it is the
        # block/no-block discriminator, a FOREIGN row does not merely widen a
        # list: it makes this account's unseeded lane look permitted, skips the
        # seam entirely, and turns a GATE_POLICY_MISSING refusal into a live
        # approval request. An alarm another tenant's row can silence is worse
        # than no alarm, because it reads as coverage.
        #
        # Asserted for EVERY discovered twin rather than for the two known ones:
        # a third gate has the identical exposure by construction, and this is
        # the same "fixed on one twin, missed on the other" drift the seam
        # exists to close (it had already happened here — FleetAutonomyService
        # carried the account filter, CveResponderService did not).
        #
        # require_approval, not auto_approve, so a regression parks an approval
        # request instead of dispatching the remediation inline.
        it "is not reached AROUND by another account's row for the same global agent" do
          other = create(:account)
          Ai::InterventionPolicy.create!(
            account: other, ai_agent_id: service.agent.id, scope: "agent",
            action_category: config[:routed_category],
            policy: "require_approval", is_active: true
          )

          result = service.gate_action!(config[:routed_category])

          expect(result[:decision]).to eq(:blocked)
          expect(result[:gate]).to eq(described_class::GATE_POLICY_MISSING)
          expect(result[:decision]).not_to eq(:pending)
          expect(result[:decision_record]).to be_nil
        end
      end
    end
  end

  describe "the misconfiguration gate stays distinguishable from every policy value" do
    it "is not confusable with an operator's own decision" do
      expect(described_class::GATE_POLICY_MISSING)
        .not_to be_in(%w[block silent unknown_policy auto_approve notify_and_proceed require_approval])
    end
  end
end
