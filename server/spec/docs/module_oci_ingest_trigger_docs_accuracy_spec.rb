# frozen_string_literal: true

require "spec_helper"

# IMP-60d756965a02 — the "ModuleOciIngestService polls the registry on a
# timer" mechanism claim, standing in five places: two paragraphs and two
# troubleshooting rows in docs/runbooks/module-authoring.md, one paragraph
# in docs/tutorials/02-first-module.md, and one line in a db seed script.
#
# It is false. ModuleOciIngestService.ingest!/ingest_native! are called
# exactly twice in the whole codebase, both from
# System::ModulePublicationProcessor#ingest_artifact
# (server/app/services/system/module_publication_processor.rb:161,171).
# That processor is reached only two ways: the Gitea module webhook
# (Api::V1::System::Webhooks::GiteaModuleController — inline in dev, or via
# the worker's System::ProcessModulePublicationJob calling back to
# Api::V1::System::WorkerApi::ModulePublicationsController#process_publication
# in production) and the native-build finalize path. There is no clock
# process, RecurringTask row, or sidekiq*.yml schedule entry anywhere —
# verified by `command grep -rniE "oci_ingest|OciIngest"` across
# extensions/system/worker and extensions/system/server/config (this spec's
# code half re-checks the same two trees so a regression reddens it), and
# separately across the top-level worker/ and server/config trees and every
# sidekiq*.yml in the repo including extensions/private/*, none of which
# name it (a literal-name sweep cannot see a scheduler composed from a
# runtime string, but none of module_publication_processor.rb's two call
# sites are reached that way either — both are inline literal calls).
#
# An operator whose webhook never fired (bad HMAC, an unregistered
# gitea_repo_full_name, a failed Gitea delivery) was told by the false claim
# to "wait 60 s for the next ingest poll" — a poll that never comes. The
# doc-half assertions below are a matched PAIR per file, same shape as
# module_promotion_docs_accuracy_spec.rb in this directory: the false claim
# must be ABSENT and a working remedy — actually checking/retriggering the
# webhook — must be PRESENT. Deleting the claim alone would pass a naive
# absence check while leaving the operator with nothing to do.
#
# What this does NOT catch: prose restating the belief in wording these
# regexes don't match, or a scheduler introduced outside the two trees the
# code half checks.
RSpec.describe "ModuleOciIngestService trigger docs vs. what actually calls it" do
  ext_root = File.expand_path("../../..", __dir__)

  def self.read(ext_root, rel)
    path = File.join(ext_root, rel)
    raise "expected #{rel} to exist under #{ext_root}" unless File.exist?(path)

    File.read(path)
  end

  # --- code: the premise the docs describe -------------------------------

  describe "the OCI ingest call sites" do
    let(:processor_src) do
      self.class.read(ext_root, "server/app/services/system/module_publication_processor.rb")
    end
    let(:webhook_controller_src) do
      self.class.read(ext_root, "server/app/controllers/api/v1/system/webhooks/gitea_module_controller.rb")
    end
    let(:worker_api_controller_src) do
      self.class.read(ext_root, "server/app/controllers/api/v1/system/worker_api/module_publications_controller.rb")
    end

    it "is called exactly twice, both from ModulePublicationProcessor#ingest_artifact" do
      expect(processor_src.scan(/::System::ModuleOciIngestService\.ingest_native!\(/).size).to eq(1)
      expect(processor_src.scan(/::System::ModuleOciIngestService\.ingest!\(/).size).to eq(1)
    end

    it "is reached only through the Gitea webhook receiver and its worker callback, not a timer" do
      expect(webhook_controller_src).to match(/::System::ModulePublicationProcessor\.process!/)
      expect(worker_api_controller_src).to match(/::System::ModulePublicationProcessor\.process!/)
    end

    it "has no scheduled/clock entry anywhere in this extension's worker or server-config trees" do
      hits = (Dir[File.join(ext_root, "worker/**/*.rb")] +
              Dir[File.join(ext_root, "worker/**/*.yml")] +
              Dir[File.join(ext_root, "server/config/**/*.yml")])
             .reject { |p| File.directory?(p) }
             .select { |p| File.read(p) =~ /oci_ingest|OciIngest/i }

      expect(hits).to eq([])
    end
  end

  # --- docs: the belief must be gone AND a working remedy present ---------

  describe "docs/runbooks/module-authoring.md" do
    let(:doc) { self.class.read(ext_root, "docs/runbooks/module-authoring.md") }

    let(:mechanism_para) do
      doc[/^The (?:Gitea webhook|platform's `ModuleOciIngestService`).*?built`\.(?: .*)?$/] ||
        raise("could not locate the ModuleOciIngestService mechanism paragraph in module-authoring.md")
    end

    let(:ingest_row) do
      doc[/^\| Module shows in registry but no `NodeModuleVersion` row \|.*$/] ||
        raise("could not locate the \"no NodeModuleVersion row\" troubleshooting row in module-authoring.md")
    end

    let(:fsverity_row) do
      doc[/^\| fs-verity digest mismatch on agent \|.*$/] ||
        raise("could not locate the \"fs-verity digest mismatch\" troubleshooting row in module-authoring.md")
    end

    it "no longer claims, in the mechanism paragraph, that ingest polls the registry" do
      expect(mechanism_para).not_to match(/polls the registry/i)
    end

    it "names ModulePublicationProcessor and the webhook in the mechanism paragraph" do
      expect(mechanism_para).to include("ModulePublicationProcessor")
      expect(mechanism_para).to match(/webhook/i)
    end

    it "no longer tells the operator to wait for a poll in the troubleshooting row" do
      expect(ingest_row).not_to match(/wait 60 ?s/i)
      expect(ingest_row).not_to match(/next ingest poll/i)
    end

    it "gives the troubleshooting row a remedy that re-fires the real trigger" do
      expect(ingest_row).to match(/redeliver/i)
      expect(ingest_row).to match(/GiteaModule|ProcessModulePublicationJob/)
    end

    # A fifth copy, found reviewing the diff for the first four: the same
    # belief restated as "re-ingests on next OCI poll" two rows below the
    # one already fixed above — a per-row guard on the first row alone would
    # not have seen it.
    it "no longer tells the operator the platform re-ingests on the next OCI poll" do
      expect(fsverity_row).not_to match(/next OCI poll/i)
    end

    it "says the re-run's webhook re-triggers ingestion instead" do
      expect(fsverity_row).to match(/webhook/i)
    end
  end

  describe "docs/tutorials/02-first-module.md" do
    let(:doc) { self.class.read(ext_root, "docs/tutorials/02-first-module.md") }

    let(:outcome_para) do
      # [\s\S]*? (not /m + greedy .*) so this stops at the first "built`."
      # on its OWN line's tail, never spilling into the rest of the file.
      # The earlier /m + greedy form captured through the file's last line
      # (8KB+), which made the "to match(/webhook/i)" assertion below
      # near-vacuous — "webhook" appears later in the tutorial regardless
      # of what this paragraph says. Caught by independent review.
      doc[/^\*\*Expected outcome:\*\* ~5[\s\S]*?built`\.[^\n]*/] ||
        raise("could not locate the Step 7 expected-outcome paragraph in 02-first-module.md")
    end

    it "no longer claims ModuleOciIngestService polls the registry" do
      expect(outcome_para).not_to match(/polls the registry/i)
    end

    it "attributes ingestion to the Step 6 webhook, not a timer" do
      expect(outcome_para).to match(/webhook/i)
      expect(outcome_para).to include("ModulePublicationProcessor")
    end
  end

  describe "server/db/seeds/example_custom_module.rb" do
    let(:seed) { self.class.read(ext_root, "server/db/seeds/example_custom_module.rb") }

    let(:ingest_line) do
      seed[/^puts "\s*4\..*$/] ||
        raise("could not locate the step-4 ingest line in example_custom_module.rb")
    end

    it "no longer prints the polling claim as step 4 of the production flow" do
      expect(ingest_line).not_to match(/polls/i)
    end

    it "names the webhook as what actually triggers ingestion" do
      expect(ingest_line).to match(/webhook/i)
    end
  end

  # A SIXTH copy, found by the independent review after the first five were
  # fixed: prose in a sibling module's own doc, describing why it does NOT
  # use the standalone per-repo pattern documented in module-authoring.md.
  describe "docs/CLAUDE_TMUX_MODULE.md" do
    let(:doc) { self.class.read(ext_root, "docs/CLAUDE_TMUX_MODULE.md") }

    let(:hosting_pattern_para) do
      doc[/^\[`docs\/runbooks\/module-authoring\.md`\][\s\S]*?for the trigger mechanism\)\./] ||
        raise("could not locate the \"Hosting pattern\" paragraph in CLAUDE_TMUX_MODULE.md")
    end

    it "no longer claims the standalone pattern uses polled ingest" do
      expect(hosting_pattern_para).not_to match(/polled ingest/i)
    end

    it "says ingest is webhook-triggered instead" do
      expect(hosting_pattern_para).to match(/webhook-triggered/i)
    end
  end
end
