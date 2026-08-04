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
end
