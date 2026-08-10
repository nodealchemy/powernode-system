# frozen_string_literal: true

require "rails_helper"

# IMP-f5923ea0f012 — hand-restated machine-truth drift: the extension
# CLAUDE.md advertised "18 seeded scripts, 8 passes" while the catalog had
# grown to 28 seeds/9 passes (33 files on disk). Counts belong in
# docs/SMOKE_TEST.md alone; the CLAUDE.md line must defer to it, never
# restate numbers that rot. Same repo-hygiene pattern as
# module_authoring_docs_stale_signing_refs_spec.
RSpec.describe "extension CLAUDE.md smoke-catalog reference hygiene" do
  it "defers to SMOKE_TEST.md without hand-restating seed or pass counts" do
    claude_md = File.read(File.expand_path("../../../CLAUDE.md", __dir__))
    smoke_lines = claude_md.lines.select { |l| l.include?("SMOKE_TEST.md") }

    expect(smoke_lines).not_to be_empty

    smoke_lines.each do |line|
      expect(line).not_to match(/\d+\s+seeded scripts?/i)
      expect(line).not_to match(/\d+\s+pass(es)?\b/i)
    end
  end
end
