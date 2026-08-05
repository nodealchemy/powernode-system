# frozen_string_literal: true

require "rails_helper"

# TemplateCloneService copies a template's joins wholesale, which is how a
# composition conflict travels: the guard on the assignment write paths is a
# DELTA, so anything a clone lands becomes permanent baseline that later
# assignments are then obliged to treat as acceptable.
#
# The clone REPRODUCES state rather than authoring it — forking a broken
# template is exactly how an operator gets a copy to repair — so it reports
# rather than refuses. What it must not do is land the conflict silently.
RSpec.describe System::TemplateCloneService do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:source)   { create(:system_node_template, account: account, node_platform: platform) }
  let(:category) { create(:system_node_module_category, account: account, name: "cat-#{SecureRandom.hex(3)}") }

  def node_module(name, variety: "subscription", in_category: category)
    create(:system_node_module, account: account, node_platform: platform,
           category: in_category, variety: variety, name: "#{name}-#{SecureRandom.hex(3)}")
  end

  def assign(mod, enabled: true)
    ::System::TemplateModule.create!(node_template: source, node_module: mod, enabled: enabled)
  end

  subject(:service) { described_class.new(source) }

  describe "#clone!" do
    it "copies the joins" do
      assign(node_module("only"))

      cloned = service.clone!(new_name: "copy-#{SecureRandom.hex(3)}")

      expect(cloned.template_modules.count).to eq(1)
    end

    context "when the source already composes badly" do
      let!(:first)  { assign(node_module("inst-a", variety: "instance")).node_module }
      let!(:second) { assign(node_module("inst-b", variety: "instance")).node_module }

      it "still clones — a colliding template has to stay forkable" do
        cloned = service.clone!(new_name: "fork-#{SecureRandom.hex(3)}")

        expect(cloned).to be_persisted
        expect(cloned.template_modules.count).to eq(2)
      end

      # Severity-typed, so a caller can tell this BLOCKING verdict — reported,
      # not enforced — from the advisory conflicts that ride the same list. It
      # used to reach the HTTP surface as a bare message String under a key
      # called `warnings` (IMP-493db0e5c398).
      it "reports the conflicts it reproduced, naming the modules" do
        service.clone!(new_name: "fork-#{SecureRandom.hex(3)}")

        blocking = service.composition_report.select { |e| e[:severity] == "error" }
        expect(blocking.map { |e| e[:kind] }).to include("instance_variety_collision")
        expect(blocking.map { |e| e[:module_ids] }.flatten)
          .to include(first.id).and include(second.id)
        expect(service.composition_message).to include(first.name).and include(second.name)
      end

      it "logs the conflict so a clone cannot land one with no trace at all" do
        expect(Rails.logger).to receive(:warn).with(/instance_variety_collision/).at_least(:once)

        service.clone!(new_name: "fork-#{SecureRandom.hex(3)}")
      end
    end

    it "reports nothing for a clean clone" do
      assign(node_module("clean"))

      service.clone!(new_name: "clean-#{SecureRandom.hex(3)}")

      expect(service.composition_report).to be_empty
      expect(service.composition_message).to be_nil
    end

    it "ignores disabled joins — a module that doesn't ship can't collide" do
      assign(node_module("live-inst", variety: "instance"))
      assign(node_module("dark-inst", variety: "instance"), enabled: false)

      service.clone!(new_name: "partial-#{SecureRandom.hex(3)}")

      expect(service.composition_report).to be_empty
    end

    # copy_template_modules! copies node_module_id verbatim, so a cross-account
    # clone's joins still point at the SOURCE account's modules. Resolving the
    # analysis against the destination would find none of them and call every
    # cross-account clone clean.
    it "still sees the conflict when cloning into another account" do
      assign(node_module("inst-a", variety: "instance"))
      assign(node_module("inst-b", variety: "instance"))

      service.clone!(new_name: "cross-#{SecureRandom.hex(3)}", account: create(:account))

      expect(service.composition_report.map { |e| e[:kind] })
        .to include("instance_variety_collision")
    end

    # The analysis is advisory here, so it must not make a working clone fail.
    it "clones anyway when the analysis itself blows up" do
      assign(node_module("boom"))
      allow_any_instance_of(::System::TemplateCompositionAnalysis)
        .to receive(:set_verdict).and_raise(StandardError, "kaboom")

      cloned = service.clone!(new_name: "resilient-#{SecureRandom.hex(3)}")

      expect(cloned).to be_persisted
      expect(service.composition_message).to include("kaboom")
    end

    # Fail closed, matching TemplateCompositionAnalysis#warning?: an analysis
    # that could not run has cleared nothing, so it must not report as an
    # advisory the caller may ignore.
    it "reports an analysis failure at BLOCKING severity, not as an advisory" do
      assign(node_module("boom"))
      allow_any_instance_of(::System::TemplateCompositionAnalysis)
        .to receive(:set_verdict).and_raise(StandardError, "kaboom")

      service.clone!(new_name: "resilient-#{SecureRandom.hex(3)}")

      expect(service.composition_report.map { |e| e[:severity] }).to eq([ "error" ])
      expect(service.composition_report.map { |e| e[:kind] }).to eq([ "composition_analysis_failed" ])
    end
  end
end
