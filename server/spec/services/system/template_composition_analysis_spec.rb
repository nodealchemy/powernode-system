# frozen_string_literal: true

require "rails_helper"

# TemplateCompositionAnalysis is the single definition of "what do these
# modules compose into" shared by compose_preview (REST + MCP) and the
# assignment write paths.
#
# The preview payload itself is covered end-to-end by the compose_preview
# request spec and the SystemFleetTool spec. What only lives here is
# #assignment_verdict's diff semantics — the reason enforcement on the write
# path does not wedge templates that already compose badly.
RSpec.describe System::TemplateCompositionAnalysis do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform) }
  let(:cat_one)  { create(:system_node_module_category, account: account, name: "one-#{SecureRandom.hex(3)}") }
  let(:cat_two)  { create(:system_node_module_category, account: account, name: "two-#{SecureRandom.hex(3)}") }

  # Names that won't collide with the account bootstrap's default catalog.
  def node_module(name, category: cat_one, variety: "subscription")
    create(:system_node_module, account: account, node_platform: platform,
           category: category, variety: variety, name: "#{name}-#{SecureRandom.hex(3)}")
  end

  # Attaches without going through the guarded write paths, so a spec can set
  # up state the guard would have refused.
  def preassign(mod, enabled: true)
    ::System::TemplateModule.create!(node_template: template, node_module: mod, enabled: enabled)
  end

  subject(:analysis) { described_class.new(account) }

  describe "#assignment_verdict" do
    it "blocks a collision the assignment itself introduces" do
      preassign(node_module("inst-a", variety: "instance"))
      incoming = node_module("inst-b", variety: "instance")

      verdict = analysis.assignment_verdict(template: template, node_module: incoming)

      expect(verdict).to be_blocked
      expect(verdict.blocking.map { |c| c[:kind] }).to include("instance_variety_collision")
      expect(verdict.message).to include(incoming.name)
    end

    # The load-bearing case. Judging the whole resulting set instead would 422
    # every subsequent assignment on a template that already collides, leaving
    # detach-everything as the only way out — so a pre-existing conflict must
    # not be charged to an unrelated assignment.
    it "does NOT block an unrelated assignment on a template that already conflicts" do
      preassign(node_module("stuck-a", variety: "instance"))
      preassign(node_module("stuck-b", variety: "instance"))
      unrelated = node_module("unrelated", category: cat_two)

      verdict = analysis.assignment_verdict(template: template, node_module: unrelated)

      expect(verdict).not_to be_blocked
      expect(verdict.message).to be_nil
    end

    it "ignores disabled joins — a module that doesn't ship can't collide" do
      preassign(node_module("disabled-inst", variety: "instance"), enabled: false)
      incoming = node_module("live-inst", variety: "instance")

      verdict = analysis.assignment_verdict(template: template, node_module: incoming)

      expect(verdict).not_to be_blocked
    end

    it "returns protected_spec overlaps as warnings rather than blocking" do
      claimer = node_module("claimer")
      claimer.update!(protected_spec: "/etc/shadow")
      preassign(claimer)
      broad = node_module("broad", category: cat_two)
      broad.update!(file_spec: "/etc/**")

      verdict = analysis.assignment_verdict(template: template, node_module: broad)

      expect(verdict).not_to be_blocked
      expect(verdict.warnings.map { |c| c[:kind] }).to include("protected_spec_overlap")
    end

    it "is clean for a first assignment onto an empty template" do
      verdict = analysis.assignment_verdict(template: template, node_module: node_module("first"))

      expect(verdict).not_to be_blocked
      expect(verdict.warnings).to be_empty
    end
  end

  # The plural form the multi-module writers need (a smoke pairing composes
  # base-os + target together, so neither is in the baseline when the other is
  # judged). Same diff semantics as the singular form.
  describe "#additions_verdict" do
    it "catches a collision BETWEEN two simultaneously-added modules" do
      first  = node_module("pair-a", variety: "instance")
      second = node_module("pair-b", variety: "instance")

      verdict = analysis.additions_verdict(template: template, node_modules: [ first, second ])

      expect(verdict).to be_blocked
      expect(verdict.blocking.map { |c| c[:kind] }).to include("instance_variety_collision")
    end

    it "still diffs against the baseline when several are added at once" do
      preassign(node_module("stuck-a", variety: "instance"))
      preassign(node_module("stuck-b", variety: "instance"))
      additions = [ node_module("ok-a", category: cat_two), node_module("ok-b", category: cat_two) ]

      verdict = analysis.additions_verdict(template: template, node_modules: additions)

      expect(verdict).not_to be_blocked
    end
  end

  # No baseline to diff against — for writers that materialize a whole
  # template in one shot (clone/import), where every conflict in the result
  # belongs to that write because there was no earlier state.
  describe "#set_verdict" do
    it "reports a conflict the whole set contains, with no baseline to excuse it" do
      first  = node_module("whole-a", variety: "instance")
      second = node_module("whole-b", variety: "instance")

      verdict = analysis.set_verdict([ first, second ])

      expect(verdict).to be_blocked
      expect(verdict.blocking.map { |c| c[:kind] }).to include("instance_variety_collision")
      expect(verdict.message).to include(first.name).and include(second.name)
    end

    it "accepts ids as readily as records" do
      mods = [ node_module("id-a", variety: "instance"), node_module("id-b", variety: "instance") ]

      expect(analysis.set_verdict(mods.map(&:id))).to be_blocked
    end

    it "is clean for a set that composes" do
      verdict = analysis.set_verdict([ node_module("solo") ])

      expect(verdict).not_to be_blocked
      expect(verdict.message).to be_nil
    end
  end

  describe "#preview_for" do
    it "persists nothing while resolving the closure" do
      required = node_module("dep-target", category: cat_two)
      dependent = node_module("dep-source")
      create(:system_module_dependency, node_module: dependent, dependency: required,
             dependency_type: "requires", required: true)

      payload = nil
      expect do
        payload = analysis.preview([ dependent.id ])
      end.not_to change { [ System::TemplateModule.count, System::NodeModule.count ] }

      # The transitively-required module rides along, flagged auto_resolved.
      expect(payload[:modules].map { |m| m[:id] }).to match_array([ dependent.id, required.id ])
      expect(payload[:modules].find { |m| m[:id] == required.id }[:auto_resolved]).to be true
      expect(payload[:modules].find { |m| m[:id] == dependent.id }[:auto_resolved]).to be false
    end
  end

  # IMP-493db0e5c398 — the projection the REPORTING surfaces (TemplateImporter,
  # TemplateCloneService) hand their callers instead of a bare message String.
  # Driven directly rather than through a fixture because the load-bearing case
  # — a conflict kind that declares NO severity — cannot be built from the
  # catalog: all three kinds TemplateComposerService#detect_conflicts emits
  # declare one today. That is exactly the case the stamping exists for, so it
  # has to be constructed.
  describe "Verdict#report_entries" do
    def verdict_for(blocking: [], warnings: [])
      described_class::Verdict.new(blocking: blocking, warnings: warnings, message: "m")
    end

    it "stamps the blocking half at error severity" do
      entries = verdict_for(blocking: [ { kind: "instance_variety_collision", severity: "error" } ]).report_entries

      expect(entries.map { |e| e[:severity] }).to eq([ "error" ])
    end

    it "stamps the advisory half at warning severity" do
      entries = verdict_for(warnings: [ { kind: "protected_spec_overlap", severity: "warning" } ]).report_entries

      expect(entries.map { |e| e[:severity] }).to eq([ "warning" ])
    end

    # #warning? partitions on `severity.to_s`, so a kind declaring a SYMBOL
    # severity lands in the advisory half carrying `:warning`. Passing the
    # declared value through instead of stamping would hand an in-process
    # caller a Symbol where every other entry carries a String, and
    # `entry[:severity] == "warning"` would silently be false.
    it "normalizes a symbol severity on the advisory half to a String" do
      entries = verdict_for(warnings: [ { kind: "protected_spec_overlap", severity: :warning } ]).report_entries

      expect(entries.map { |e| e[:severity] }).to eq([ "warning" ])
    end

    # The fail-closed rule in #warning? puts a severity-less conflict kind into
    # `blocking`. If report_entries passed the declared value through instead of
    # stamping, that entry would report severity nil — leaving the caller
    # exactly as unable to classify it as the untyped `warnings` key this
    # replaces, while every surface still looked correct.
    it "stamps error severity on a blocking conflict that declares none" do
      entries = verdict_for(blocking: [ { kind: "future_kind_with_no_severity" } ]).report_entries

      expect(entries.map { |e| e[:severity] }).to eq([ "error" ])
      expect(entries.first[:kind]).to eq("future_kind_with_no_severity")
    end

    # A blocking conflict that mislabels ITSELF as a warning must still report
    # as blocking: the verdict already partitioned it, and the partition is
    # what the caller is being told about.
    it "reports a conflict the partition placed in blocking at error severity, whatever it declared" do
      entries = verdict_for(blocking: [ { kind: "mislabelled", severity: "warning" } ]).report_entries

      expect(entries.map { |e| e[:severity] }).to eq([ "error" ])
    end

    it "carries both halves in one list, each distinguishable by its own severity" do
      entries = verdict_for(
        blocking: [ { kind: "instance_variety_collision", severity: "error" } ],
        warnings: [ { kind: "protected_spec_overlap", severity: "warning" } ]
      ).report_entries

      expect(entries.size).to eq(2)
      expect(entries.select { |e| e[:severity] == "error" }.map { |e| e[:kind] })
        .to eq([ "instance_variety_collision" ])
      expect(entries.select { |e| e[:severity] == "warning" }.map { |e| e[:kind] })
        .to eq([ "protected_spec_overlap" ])
    end

    it "reports nothing for a clean verdict" do
      expect(verdict_for.report_entries).to be_empty
    end

    it "leaves the caller's conflict hashes unmutated" do
      conflict = { kind: "instance_variety_collision", severity: "error" }
      verdict_for(blocking: [ conflict ]).report_entries

      expect(conflict).to eq({ kind: "instance_variety_collision", severity: "error" })
    end
  end

  # IMP-ba082cb22bda — the one shared implementation of the fail-closed
  # composition-verdict report used by the whole-template writers (clone +
  # import). Previously duplicated near-verbatim in both services, where a
  # change to the fail-closed contract in one copy would silently strand the
  # other.
  describe ".report_for" do
    let(:mod) do
      create(:system_node_module, account: account, node_platform: platform,
             category: cat_one, variety: "subscription", name: "rf-mod-#{SecureRandom.hex(3)}")
    end

    it "returns the verdict report and message for a clean composition" do
      result = described_class.report_for(
        account: account, modules: [ mod.id ],
        log_tag: "SpecCaller", subject: "spec template"
      )

      expect(result[:blocked]).to be(false)
      expect(result[:report]).to eq([])
      # A clean verdict carries no message (prebuilt only for conflicts) —
      # the key exists but nil is the preserved contract.
      expect(result).to have_key(:message)
    end

    it "fails closed at blocking severity when the analysis itself raises" do
      allow_any_instance_of(described_class).to receive(:set_verdict)
        .and_raise(StandardError, "boom")
      expect(Rails.logger).to receive(:warn)
        .with(a_string_matching(/\[SpecCaller\] composition analysis failed: boom/))

      result = described_class.report_for(
        account: account, modules: [ mod.id ],
        log_tag: "SpecCaller", subject: "spec template"
      )

      expect(result[:blocked]).to be(true)
      expect(result[:report].map { |e| e[:kind] }).to eq([ "composition_analysis_failed" ])
      expect(result[:report].first[:severity]).to eq(described_class::BLOCKING_SEVERITY)
    end

    it "fails closed when resolving the module scope itself raises" do
      # Keyword arguments evaluate at the CALL SITE, so callers pass the LAZY
      # scope and the pluck runs inside this method's rescue — a DB blip while
      # resolving modules must produce the advisory report, never escape into
      # (and fail) an otherwise-good clone/import.
      scope = System::NodeModule.none
      allow(scope).to receive(:pluck).and_raise(StandardError, "db blip")

      result = nil
      expect {
        result = described_class.report_for(
          account: account, modules: scope,
          log_tag: "SpecCaller", subject: "spec template"
        )
      }.not_to raise_error

      expect(result[:blocked]).to be(true)
      expect(result[:report].map { |e| e[:kind] }).to eq([ "composition_analysis_failed" ])
    end
  end
end
