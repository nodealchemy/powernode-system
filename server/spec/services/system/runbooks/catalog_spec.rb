# frozen_string_literal: true

require "rails_helper"
require "tmpdir"

# Campaign 01a08c9b increment B4a (design §5.2) — runbook coverage for every
# signal kind the fleet can emit.
#
# THIS SPEC LIVES IN THE EXTENSION because the question it asks is
# "does every kind in System::Fleet::DecisionEngine::SIGNAL_BINDINGS have an
# entry", and SIGNAL_BINDINGS is extension-side. Core's
# Platform::Runbook::Registry (A5) consumes the catalog; it cannot assert this.
RSpec.describe System::Runbooks::Catalog do
  let(:bound_kinds) { System::Fleet::DecisionEngine::SIGNAL_BINDINGS.keys.map(&:to_s) }
  let(:catalog)     { described_class.load }

  # A helper that writes a MUTATED copy of the real catalog and loads it. Every
  # negative example below goes through this, so each one is the real catalog
  # plus exactly one defect — a checker that passed a wholly synthetic fixture
  # would not prove anything about the file that ships.
  def catalog_with(mutation)
    entries = YAML.safe_load(described_class::DEFAULT_PATH.read)
    mutation.call(entries)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "runbooks.yml")
      File.write(path, entries.to_yaml)
      yield described_class.load(path: path)
    end
  end

  describe "the catalog that ships" do
    it "validates clean against the bound signal kinds" do
      expect(catalog.validate(bound_kinds: bound_kinds)).to eq([])
    end

    it "covers every bound kind exactly once, with no entry for an unbound kind" do
      expect(catalog.entries.keys).to match_array(bound_kinds)
    end

    it "prefers a real runbook over not_documented for the majority of kinds" do
      documented = catalog.entries.count { |_kind, entry| entry.key?("doc") }

      # Not a vanity metric: the increment's acceptance is "every bound kind has
      # a runbook entry OR a reasoned not_documented", and a catalog that took
      # the second branch everywhere would satisfy the letter of that while
      # documenting nothing. This is the floor under that loophole.
      expect(documented).to be > (catalog.entries.size / 2)
    end

    it "resolves every doc: entry to a file on disk" do
      documented = catalog.entries.keys.select { |kind| catalog.documented?(kind) }

      expect(documented).to be_present
      documented.each do |kind|
        expect(catalog.resolved_path(kind)).to be_file, "#{kind} points at a missing file"
      end
    end

    it "contains every shipped doc path inside the extension root" do
      # The other arm of the containment check: a real entry must resolve, not
      # merely fail to escape.
      catalog.entries.keys.select { |kind| catalog.documented?(kind) }.each do |kind|
        path = catalog.resolved_path(kind).to_s

        expect(path).to start_with("#{described_class::EXTENSION_ROOT}/")
      end
    end

    it "distinguishes an unknown kind from a not_documented one" do
      not_documented = catalog.entries.find { |_kind, entry| entry["not_documented"] }&.first
      expect(not_documented).to be_present

      # A caller has to be able to tell "nobody decided" (nil) from "decided,
      # nothing to point at" (an entry) — the front door renders them
      # differently.
      expect(catalog.for(not_documented)).to include("not_documented" => true)
      expect(catalog.for("system.no_such_kind_at_all")).to be_nil
      expect(catalog.documented?(not_documented)).to be(false)
    end
  end

  describe "the checker's failing arm" do
    it "reports a bound kind that has no entry" do
      dropped = bound_kinds.first

      catalog_with(->(entries) { entries.delete(dropped) }) do |mutated|
        problems = mutated.validate(bound_kinds: bound_kinds)

        expect(problems).to include(a_string_matching(/#{Regexp.escape(dropped)}.*absent from/))
      end
    end

    it "reports an entry that names no bound kind" do
      catalog_with(->(entries) { entries["system.invented_kind"] = { "not_documented" => true, "reason" => "x" } }) do |mutated|
        problems = mutated.validate(bound_kinds: bound_kinds)

        expect(problems).to include(a_string_matching(/system\.invented_kind.*bound by no SIGNAL_BINDINGS/))
      end
    end

    it "reports a doc: anchor that matches no heading in the file" do
      kind = catalog.entries.keys.find { |k| catalog.documented?(k) }

      catalog_with(->(entries) { entries[kind]["doc"] = "docs/runbooks/node-provisioning.md#no-such-heading" }) do |mutated|
        problems = mutated.validate(bound_kinds: bound_kinds)

        expect(problems).to include(a_string_matching(/#{Regexp.escape(kind)}.*no heading whose anchor is #no-such-heading/))
      end
    end

    it "reports a doc: file that does not exist" do
      kind = catalog.entries.keys.find { |k| catalog.documented?(k) }

      catalog_with(->(entries) { entries[kind]["doc"] = "docs/runbooks/not-a-runbook.md#anything" }) do |mutated|
        expect(mutated.validate(bound_kinds: bound_kinds))
          .to include(a_string_matching(/#{Regexp.escape(kind)}.*does not exist/))
      end
    end

    it "reports a doc: with no #anchor at all" do
      kind = catalog.entries.keys.find { |k| catalog.documented?(k) }

      catalog_with(->(entries) { entries[kind]["doc"] = "docs/runbooks/node-provisioning.md" }) do |mutated|
        expect(mutated.validate(bound_kinds: bound_kinds))
          .to include(a_string_matching(/#{Regexp.escape(kind)}.*carries no #anchor/))
      end
    end

    it "reports a not_documented entry whose reason is blank" do
      kind = catalog.entries.find { |_k, entry| entry["not_documented"] }.first

      catalog_with(->(entries) { entries[kind]["reason"] = "   " }) do |mutated|
        expect(mutated.validate(bound_kinds: bound_kinds))
          .to include(a_string_matching(/#{Regexp.escape(kind)}.*require a non-empty reason/))
      end
    end

    it "reports an entry that declares both doc: and not_documented:" do
      kind = catalog.entries.keys.find { |k| catalog.documented?(k) }

      catalog_with(->(entries) { entries[kind]["not_documented"] = true }) do |mutated|
        expect(mutated.validate(bound_kinds: bound_kinds))
          .to include(a_string_matching(/#{Regexp.escape(kind)}.*declares both doc/))
      end
    end

    it "reports an entry that declares neither" do
      kind = catalog.entries.keys.find { |k| catalog.documented?(k) }

      catalog_with(->(entries) { entries[kind] = { "reason" => "orphaned" } }) do |mutated|
        expect(mutated.validate(bound_kinds: bound_kinds))
          .to include(a_string_matching(/#{Regexp.escape(kind)}.*declares neither/))
      end
    end

    it "reports an unknown key rather than silently ignoring it" do
      kind = catalog.entries.keys.find { |k| catalog.documented?(k) }

      # The defect this guards: `not_documeted: true` would otherwise be an
      # unread key on an entry that still has its doc, and the typo would never
      # surface.
      catalog_with(->(entries) { entries[kind]["not_documeted"] = true }) do |mutated|
        expect(mutated.validate(bound_kinds: bound_kinds))
          .to include(a_string_matching(/#{Regexp.escape(kind)}.*unknown key/))
      end
    end

    it "rejects a doc path that walks out of the extension root" do
      kind = catalog.entries.keys.find { |k| catalog.documented?(k) }

      catalog_with(->(entries) { entries[kind]["doc"] = "../../../../etc/passwd#anything" }) do |mutated|
        expect(mutated.validate(bound_kinds: bound_kinds))
          .to include(a_string_matching(/#{Regexp.escape(kind)}.*escapes the extension root/))
        # And the seam A5 reads through refuses it too, rather than handing
        # back a path outside the extension for someone else to open.
        expect(mutated.resolved_path(kind)).to be_nil
      end
    end

    it "rejects an absolute doc path, which Pathname#join would otherwise honour" do
      kind = catalog.entries.keys.find { |k| catalog.documented?(k) }

      catalog_with(->(entries) { entries[kind]["doc"] = "/etc/passwd#anything" }) do |mutated|
        expect(mutated.validate(bound_kinds: bound_kinds))
          .to include(a_string_matching(/#{Regexp.escape(kind)}.*escapes the extension root/))
        expect(mutated.resolved_path(kind)).to be_nil
      end
    end

    it "raises rather than returning an empty catalog when the file is missing" do
      expect { described_class.load(path: "/nonexistent/runbooks.yml") }
        .to raise_error(described_class::LoadError, /not found/)
    end
  end

  describe ".slug" do
    it "reproduces GitHub's heading anchors, hyphen runs and all" do
      expect(described_class.slug("Per-state error recovery")).to eq("per-state-error-recovery")
      expect(described_class.slug("Phase 4 — Run ✅")).to eq("phase-4--run-")
      expect(described_class.slug("Step 4 — Renew (manual or automatic)")).to eq("step-4--renew-manual-or-automatic")
      expect(described_class.slug("A `fleet.governance_gap_stuck` event")).to eq("a-fleetgovernance_gap_stuck-event")
    end

    it "does not collapse the spaces a removed character leaves behind" do
      # Both arms of the rule that matters: tidying this would produce anchors
      # that read better and resolve to nothing.
      expect(described_class.slug("Phase 1 — CVE ingest ✅")).to eq("phase-1--cve-ingest-")
      expect(described_class.slug("Phase 1 — CVE ingest ✅")).not_to eq("phase-1-cve-ingest")
    end
  end

  describe ".heading_slugs" do
    it "finds real headings and ignores a # comment inside a code fence" do
      Dir.mktmpdir do |dir|
        file = File.join(dir, "sample.md")
        File.write(file, <<~MD)
          # Real heading

          ```bash
          # Not a heading, a shell comment
          ```

          ## Second real heading
        MD

        slugs = described_class.heading_slugs(file)

        expect(slugs).to eq(%w[real-heading second-real-heading])
        expect(slugs).not_to include("not-a-heading-a-shell-comment")
      end
    end
  end
end
