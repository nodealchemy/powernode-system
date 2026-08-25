# frozen_string_literal: true

require "rails_helper"

# IMP-26b7f0004a49 phase 1 — the promote-time core-drift gate.
#
# A Class-B module's erofs payload is assembled from a parent clone of
# powernode-platform that stage15.sh makes with a bare `git clone --depth 1`
# against GitHub — no ref, no pin. Core pushes go to Gitea; GitHub is a
# separately-pushed mirror that lags arbitrarily (three days on 2026-08-15,
# five merges again on 2026-08-16). An artifact built from a stale mirror
# reports IDENTICALLY to a correct one at every existing checkpoint: real
# oci_digest, real fsverity root, batch success, cosign signature, size well
# above the non-empty floor. Publish auto-promotes, so it reaches the fleet.
#
# This gate is the first checkpoint that can tell the two apart, by comparing
# the core sha stamped onto the published artifact (OCI annotation
# org.powernode.core_source_sha, written by push.sh) against the core commit
# the batch was dispatched expecting.
RSpec.describe System::CoreProvenanceGate do
  let(:expected) { "3280a3cd2aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }
  let(:stale)    { "b6f6947811111111111111111111111111111111" }

  def annotations(sha: nil, remote: "github.com/nodealchemy/powernode-platform")
    doc = {}
    doc[described_class::SHA_ANNOTATION]    = sha    if sha
    doc[described_class::REMOTE_ANNOTATION] = remote if remote
    doc
  end

  def verdict_for(module_name:, expected_sha: nil, annotations: {})
    described_class.evaluate(module_name: module_name, expected_sha: expected_sha,
                             annotations: annotations)
  end

  describe "the Class-B module set" do
    # stage15.sh's `needs_parent` case statement is the authority. A module
    # that is not in it clones no parent, so it has no core content and there
    # is nothing for this gate to compare.
    it "lists exactly the four modules stage15.sh clones the parent for" do
      expect(described_class::CLASS_B_PARENT_MODULES).to contain_exactly(
        "powernode-hub-backend", "powernode-hub-worker",
        "powernode-hub-frontend", "powernode-extension-system"
      )
    end

    # There must be ONE list. The node_api config controller mints PARENT_PAT
    # off the same set; a second copy is a set that drifts.
    it "is the same object the node_api config controller mints PARENT_PAT from" do
      expect(::Api::V1::System::NodeApi::ConfigController::CLASS_B_PARENT_MODULES)
        .to equal(described_class::CLASS_B_PARENT_MODULES)
    end
  end

  describe "Class-A modules (clone no parent)" do
    # push.sh only stamps the annotation when stage15.sh's Class-B arm wrote
    # /tmp/parent-provenance.env, and stage15.sh rm -f's that file first, so a
    # Class-A artifact carries NO annotation at all. Absent must read as "this
    # module has no core content", never as "provenance went missing".
    it "passes with no annotation at all" do
      v = verdict_for(module_name: "runtime-go", expected_sha: expected)

      expect(v).to be_promotable
      expect(v.state).to eq("not_applicable")
    end

    it "passes even when an expectation is recorded and a DIFFERENT sha is somehow stamped" do
      v = verdict_for(module_name: "runtime-go", expected_sha: expected,
                      annotations: annotations(sha: stale))

      expect(v).to be_promotable
      expect(v.state).to eq("not_applicable")
    end
  end

  describe "Class-B modules" do
    it "passes when the stamped core sha is the sha the batch expected" do
      v = verdict_for(module_name: "powernode-hub-backend", expected_sha: expected,
                      annotations: annotations(sha: expected))

      expect(v).to be_promotable
      expect(v.state).to eq("match")
      expect(v.actual_sha).to eq(expected)
    end

    it "is case-insensitive about the sha (git prints lowercase; nothing guarantees it)" do
      v = verdict_for(module_name: "powernode-hub-backend", expected_sha: expected.upcase,
                      annotations: annotations(sha: expected))

      expect(v).to be_promotable
      expect(v.state).to eq("match")
    end

    # THE INCIDENT. hub-backend v71 shipped three-day-old core on 2026-08-15
    # and cost two outages; it was found only by unpacking the layer and
    # diffing a file by hand.
    it "REFUSES when the artifact carries a different core sha than the batch expected" do
      v = verdict_for(module_name: "powernode-hub-backend", expected_sha: expected,
                      annotations: annotations(sha: stale))

      expect(v).not_to be_promotable
      expect(v.state).to eq("mismatch")
      expect(v.expected_sha).to eq(expected)
      expect(v.actual_sha).to eq(stale)
      expect(v.reason).to include(stale[0, 7])
      expect(v.reason).to include(expected[0, 7])
    end

    # The remote is carried because the incident was a RIGHT BRANCH NAME on a
    # STALE MIRROR — the sha alone looked entirely plausible. An operator
    # reading the refusal needs to know which host it came from.
    it "names the remote the artifact's core actually came from in the refusal" do
      v = verdict_for(module_name: "powernode-hub-backend", expected_sha: expected,
                      annotations: annotations(sha: stale, remote: "github.com/nodealchemy/powernode-platform"))

      expect(v.actual_remote).to eq("github.com/nodealchemy/powernode-platform")
      expect(v.reason).to include("github.com/nodealchemy/powernode-platform")
    end

    # stage15.sh records the literal `unknown` when `git rev-parse --verify
    # HEAD` fails, precisely so an absent value is never indistinguishable
    # from a successful one. It means "this artifact HAS core content and the
    # sha could not be resolved" — the one reading that must not promote.
    it "REFUSES on the literal `unknown`" do
      v = verdict_for(module_name: "powernode-hub-backend", expected_sha: expected,
                      annotations: annotations(sha: "unknown"))

      expect(v).not_to be_promotable
      expect(v.state).to eq("unresolved")
    end

    # stage15.sh:262 documents this as a reachable fourth state: a BARE
    # `git rev-parse HEAD` on an unborn head prints the literal "HEAD".
    # `--verify` closes it at the source, but a gate that trusted whatever
    # string arrived would promote on it.
    it "REFUSES on a value that is not a sha at all (the literal `HEAD`)" do
      v = verdict_for(module_name: "powernode-hub-backend", expected_sha: expected,
                      annotations: annotations(sha: "HEAD"))

      expect(v).not_to be_promotable
      expect(v.state).to eq("malformed")
    end

    # A Class-B artifact with no annotation means the stamping did not run —
    # an old builder, or a push.sh that lost the block. That is exactly the
    # blind spot this gate exists to close, so it cannot be the pass case.
    it "REFUSES when a Class-B artifact carries no core annotation at all" do
      v = verdict_for(module_name: "powernode-hub-backend", expected_sha: expected)

      expect(v).not_to be_promotable
      expect(v.state).to eq("missing")
    end

    # module-forge-build.sh already emits the literal `not_applicable` in its
    # result JSON for a module that clones no parent. If a future push.sh ever
    # stamps that onto an artifact, a Class-B module carrying it means the
    # provenance capture did not run — the module NAME is the authority here
    # (stage15.sh decides whether to clone a parent before any artifact exists),
    # and the artifact's self-report is precisely what cannot be trusted.
    it "REFUSES a Class-B artifact that reports `not_applicable` about itself" do
      v = verdict_for(module_name: "powernode-hub-backend", expected_sha: expected,
                      annotations: annotations(sha: "not_applicable"))

      expect(v).not_to be_promotable
      expect(v.state).to eq("contradictory")
    end

    # Every batch dispatched before this change carries no expectation. The
    # gate must be INERT for them rather than stalling in-flight work — we
    # never fabricate an expectation we did not resolve.
    it "passes when the batch recorded no expectation (pre-change / unresolvable)" do
      v = verdict_for(module_name: "powernode-hub-backend", expected_sha: nil,
                      annotations: annotations(sha: stale))

      expect(v).to be_promotable
      expect(v.state).to eq("no_expectation")
    end

    it "treats a blank expectation the same as a missing one" do
      v = verdict_for(module_name: "powernode-hub-backend", expected_sha: "   ",
                      annotations: annotations(sha: stale))

      expect(v).to be_promotable
      expect(v.state).to eq("no_expectation")
    end

    # git's own abbreviation rules: an abbreviated sha on either side is a
    # match if it is a prefix and long enough to be unambiguous. Refusing a
    # correct build because one side was abbreviated is a false positive, and
    # a gate that cries wolf is a gate an operator turns off.
    it "accepts an abbreviated sha on either side when it is a long-enough prefix" do
      short = expected[0, 12]

      expect(verdict_for(module_name: "powernode-hub-backend", expected_sha: short,
                         annotations: annotations(sha: expected))).to be_promotable
      expect(verdict_for(module_name: "powernode-hub-backend", expected_sha: expected,
                         annotations: annotations(sha: short))).to be_promotable
    end

    # 7 hex characters is 268M possibilities; a prefix that short is a
    # coincidence waiting to happen, and this gate's whole job is to tell two
    # plausible-looking shas apart. So it is not accepted as a MATCH —
    # but an expectation too short to be an identity is not evidence of a
    # mismatch either, and this used to refuse on it. See the block below.
    it "does not treat a prefix too short to be an identity as a match" do
      v = verdict_for(module_name: "powernode-hub-backend", expected_sha: expected[0, 7],
                      annotations: annotations(sha: expected))

      expect(v.state).not_to eq("match")
    end
  end

  # Regression: 2026-08-24/25. Four consecutive batches of
  # powernode-extension-system and powernode-hub-backend built sound, signed,
  # correctly-provenanced artifacts that never reached the fleet. A
  # core-SOURCED batch records its own head_sha as the expectation, and this
  # platform dispatches with the short tag form, so `expected` arrived as 9
  # characters against a 40-character annotation. #same_commit? answers false
  # for any prefix under MIN_ABBREV_LENGTH and the gate read that false as
  # "mismatch" — refusing every core-sourced build, correct ones included.
  describe "an expectation too short to be a commit identity" do
    let(:expected) { "b01d7c47c9f1e2a3b4c5d6e7f8091a2b3c4d5e6f" }
    let(:short)    { expected[0, 9] }

    def verdict
      verdict_for(module_name: "powernode-extension-system", expected_sha: short,
                  annotations: annotations(sha: expected, remote: "github.com/nodealchemy/powernode-platform"))
    end

    it "does not refuse promotion on it" do
      expect(verdict).to be_promotable
    end

    it "reports that nothing was checked rather than claiming a mismatch" do
      expect(verdict.state).to eq("unusable_expectation")
      expect(verdict.reason).to include("NOT CHECKED")
    end

    it "agrees with System::CoreMirrorPreflight, which never refused this input" do
      expect(described_class.usable_expectation?(short)).to be false
      expect(described_class.usable_expectation?(expected)).to be true
    end

    # A DIFFERING prefix is conclusive at any length — the stale-mirror threat
    # this gate exists for produces an unrelated sha, so it is still refused.
    it "still refuses when a short expectation DISAGREES with the artifact" do
      v = verdict_for(module_name: "powernode-extension-system", expected_sha: "deadbeef1",
                      annotations: annotations(sha: expected))

      expect(v).not_to be_promotable
      expect(v.state).to eq("mismatch")
    end
  end

  # The reason this went undiagnosed across four deploys: the refusal printed
  # the same seven characters on both sides of "but this batch expected".
  describe "a refusal a human can act on" do
    it "never renders the two shas identically" do
      a = "b01d7c47c9f1e2a3b4c5d6e7f8091a2b3c4d5e6f"
      b = "b01d7c47cAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA".downcase
      shown_a, shown_b = described_class.contrast(a, b)

      expect(shown_a).not_to eq(shown_b)
    end

    it "shows the full values when one is a prefix of the other" do
      a = "b01d7c47c9f1e2a3b4c5d6e7f8091a2b3c4d5e6f"
      expect(described_class.contrast(a, a[0, 9])).to eq([ a, a[0, 9] ])
    end

    it "puts distinguishable shas in the mismatch reason itself" do
      expected = "b01d7c47c9f1e2a3b4c5d6e7f8091a2b3c4d5e6f"
      actual   = "b01d7c47c0000000000000000000000000000000"
      v = verdict_for(module_name: "powernode-hub-backend", expected_sha: expected,
                      annotations: annotations(sha: actual))

      expect(v.state).to eq("mismatch")
      built, batch_expected = v.reason.scan(/core ([0-9a-f]+)/).flatten
      expect(built).not_to eq(batch_expected)
    end
  end

  describe "operator kill switch" do
    it "passes everything when system.module_publish.core_provenance_gate is disabled" do
      SiteSetting.set("system.module_publish.core_provenance_gate", "false", setting_type: "string")

      v = verdict_for(module_name: "powernode-hub-backend", expected_sha: expected,
                      annotations: annotations(sha: stale))

      expect(v).to be_promotable
      expect(v.state).to eq("disabled")
    end

    # Default-on. A gate an operator has to remember to switch on is not a gate.
    it "is enabled when the setting was never written" do
      expect(described_class.enabled?).to be true
    end

    # SiteSetting hands back a real Integer for setting_type "integer", and 0 is
    # TRUTHY in Ruby — an operator who writes 0 meaning "off" must not get a
    # switch that silently does nothing.
    it "treats an integer 0 as off" do
      SiteSetting.set("system.module_publish.core_provenance_gate", "0", setting_type: "integer")

      expect(described_class.enabled?).to be false
    end

    it "treats a boolean false as off" do
      allow(SiteSetting).to receive(:get)
        .with("system.module_publish.core_provenance_gate").and_return(false)

      expect(described_class.enabled?).to be false
    end

    it "stays enabled when the SiteSetting lookup itself raises" do
      allow(SiteSetting).to receive(:get).and_raise(StandardError, "settings table gone")

      expect(described_class.enabled?).to be true
    end
  end

  describe ".inert" do
    # Every non-native publish path (Gitea webhook, CI-direct REST publish)
    # has no batch and no expectation. It must reach a passing verdict without
    # having to hand-build an empty annotation hash.
    it "is a passing verdict for callers with no native build context" do
      expect(described_class.inert).to be_promotable
      expect(described_class.inert.state).to eq("not_native")
    end
  end

  describe "input tolerance" do
    it "treats a nil annotations argument as no annotations" do
      v = verdict_for(module_name: "powernode-hub-backend", expected_sha: expected,
                      annotations: nil)

      expect(v).not_to be_promotable
      expect(v.state).to eq("missing")
    end

    it "treats a non-Hash annotations argument as no annotations" do
      v = verdict_for(module_name: "powernode-hub-backend", expected_sha: expected,
                      annotations: "not-a-hash")

      expect(v).not_to be_promotable
      expect(v.state).to eq("missing")
    end

    it "treats a blank module name as Class-A rather than raising" do
      v = verdict_for(module_name: nil, expected_sha: expected)

      expect(v).to be_promotable
      expect(v.state).to eq("not_applicable")
    end
  end
end
