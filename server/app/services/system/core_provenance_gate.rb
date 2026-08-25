# frozen_string_literal: true

module System
  # IMP-26b7f0004a49 phase 1 — decides whether a natively-built module artifact
  # may be PROMOTED, given the core (parent powernode-platform) commit it was
  # actually assembled from.
  #
  # WHY THIS EXISTS
  #
  # A Class-B module's payload is built on top of a parent clone that
  # scripts/module-build/stage15.sh makes against a remote defaulting to
  # github.com/nodealchemy/powernode-platform. Core pushes go to Gitea; GitHub
  # is a separately-pushed mirror that lags arbitrarily.
  #
  # HISTORY, because it explains this gate's shape: that clone used to be a bare
  # `git clone --depth 1 "$clone_url" /tmp/parent` — no ref, no pin — so the
  # build took whatever the mirror's default branch happened to point at.
  # stage15.sh now fetches the batch's own expected_core_sha when the platform
  # supplies one (delivered as CORE_REF via ci_build_context), which is a THIRD
  # layer alongside this gate and System::CoreMirrorPreflight. This gate is not
  # redundant: the pinned arm is skipped whenever no expectation was recorded,
  # the Gitea-Actions path sends no pin at all, and — the reason it must keep
  # measuring rather than trusting — a pin is an INTENTION while the annotation
  # this reads is what is actually on disk.
  #
  # An artifact assembled from a stale mirror is INDISTIN-
  # GUISHABLE from a correct one at every checkpoint the platform already has:
  # it has a real oci_digest, a real fs-verity root, a valid cosign signature, a
  # size far above the non-empty floor, and a batch that reports success. Publish
  # auto-promotes, so it reaches the fleet. That is what shipped hub-backend v71
  # with three-day-old core on 2026-08-15 and cost two outages; it was found only
  # by unpacking the layer and diffing a file by hand.
  #
  # The one signal that separates the two is the core sha push.sh:271-299 stamps
  # onto the published artifact as the OCI manifest annotation
  # `org.powernode.core_source_sha`. Deliberately NOT read from
  # NodeModuleVersion#artifacts: the agent's `moduleBuildResult` Go struct does
  # not decode the matching result-JSON keys (encoding/json drops unknown
  # fields), so that column is nil forever and a gate reading it would never
  # fire — worse than no gate, because it looks like protection.
  #
  # KNOWN LIMITATION (phase 1): the comparison is EQUALITY, so it is blind to
  # DIRECTION. It cannot distinguish "the artifact's core is older than the
  # expectation" (the stale-mirror incident this exists for) from "core simply
  # moved between dispatch and clone" — both refuse. That is the safe direction
  # and the cost is bounded: the version still publishes, the fleet keeps what it
  # already had, and the operator gets a high-severity event naming both shas and
  # the remote. Turning it into an ancestry test needs a compare API call against
  # the core repo and is deliberately out of scope here.
  #
  # FAIL-CLOSED, BUT ONLY WHERE THERE IS SOMETHING TO COMPARE. The batch's
  # recorded expectation is what arms this gate. A batch that recorded none
  # (dispatched before this existed, or a core tip that would not resolve) leaves
  # it inert — we never fabricate an expectation, and never stall in-flight work
  # over an answer we did not have. Once a USABLE expectation is recorded, every
  # reading other than "matches" refuses, including the absence of the
  # annotation: a Class-B artifact that arrives unstamped means the stamping did
  # not run, which is precisely the blind spot being closed.
  #
  # "Usable" is load-bearing, and is the same bar System::CoreMirrorPreflight
  # applies: a recorded expectation too short to be a commit identity (see
  # MIN_ABBREV_LENGTH) is not evidence about the artifact and is NOT refused on.
  # Refusing it made this gate reject four consecutive good builds while
  # reporting two identical seven-character shas as a "mismatch". The remedy for
  # the resulting blind spot belongs at the producer — a batch should record a
  # full sha — not in a refusal this gate cannot justify.
  class CoreProvenanceGate
    # Modules whose Stage-1.5 arm actually clones the PARENT platform repo.
    # MUST stay in sync with scripts/module-build/stage15.sh's `needs_parent`
    # case statement — that script is the authority. Every other module clones
    # no parent, carries no core content, and has nothing for this gate to
    # compare.
    #
    # Single source of truth: Api::V1::System::NodeApi::ConfigController (which
    # mints PARENT_PAT for exactly this set) points its own constant here rather
    # than keeping a second copy, because a set defined twice is a set that
    # drifts.
    CLASS_B_PARENT_MODULES = %w[
      powernode-hub-backend powernode-hub-worker powernode-hub-frontend
      powernode-extension-system
    ].freeze

    SHA_ANNOTATION    = "org.powernode.core_source_sha"
    REMOTE_ANNOTATION = "org.powernode.core_source_remote"

    # stage15.sh's provenance capture records this literal when
    # `git rev-parse --verify HEAD` fails, specifically so an unresolved value
    # is never indistinguishable from a successful one. It means "this artifact HAS core content and the sha
    # could not be resolved" — which cannot be promoted on.
    UNRESOLVED_SHA = "unknown"

    # What module-forge-build.sh reports for a module that clones no parent.
    # Today it never reaches an OCI annotation — a Class-A artifact simply
    # carries none (stage15.sh rm -f's the provenance file before deciding
    # whether to clone a parent, and only the needs_parent arm rewrites it) —
    # and the module-NAME check is
    # what recognises that case. Named here so that if a future push.sh does
    # stamp it, a Class-B artifact carrying it is refused rather than silently
    # excused by its own self-report.
    NOT_APPLICABLE_SHA = "not_applicable"

    ENABLED_SETTING = "system.module_publish.core_provenance_gate"

    # A prefix shorter than this is not an identity. 7 hex characters is 268M
    # possibilities — a coincidence waiting to happen, and telling two
    # plausible-looking shas apart is this gate's entire job. 12 is git's own
    # threshold for a "reasonably unambiguous" abbreviation on a large repo.
    MIN_ABBREV_LENGTH = 12

    SHA_PATTERN = /\A[0-9a-f]{7,40}\z/

    Verdict = Struct.new(:promotable, :state, :reason, :expected_sha, :actual_sha, :actual_remote,
                         keyword_init: true) do
      def promotable?
        promotable
      end

      def refused?
        !promotable
      end
    end

    class << self
      # @param module_name [String, nil] the module slug (System::NodeModule#name)
      # @param expected_sha [String, nil] the core commit the batch was dispatched
      #   expecting; nil/blank leaves the gate inert
      # @param annotations [Hash, nil] the published artifact's OCI manifest
      #   annotations, as surfaced by ModuleOciIngestService::Result#oci_annotations
      # @return [Verdict]
      def evaluate(module_name:, expected_sha:, annotations:)
        ann      = annotations.is_a?(Hash) ? annotations : {}
        actual   = ann[SHA_ANNOTATION].to_s.strip
        remote   = ann[REMOTE_ANNOTATION].to_s.strip.presence
        expected = expected_sha.to_s.strip

        unless class_b?(module_name)
          return pass("not_applicable",
                      "#{module_name.presence || 'module'} clones no parent — it carries no core content",
                      expected: expected, actual: actual, remote: remote)
        end

        # For a Class-B module the NAME is the authority (stage15.sh decides
        # whether to clone a parent from its own `needs_parent` case, before any
        # artifact exists) — the artifact's self-report is exactly the thing that
        # cannot be trusted here. build-one-module.sh already emits the literal
        # `not_applicable` in its result JSON, so an artifact claiming it while
        # being a module we KNOW clones core means the provenance capture went
        # wrong. Accepting it would reopen the "the stamping did not run" hole
        # that the `missing` branch below exists to close.
        if actual == NOT_APPLICABLE_SHA
          return refuse("contradictory",
                        "#{module_name} is built on a clone of core, but the artifact reports " \
                        "`#{NOT_APPLICABLE_SHA}` — its core provenance capture did not run",
                        expected: expected, actual: actual, remote: remote)
        end

        if expected.blank?
          return pass("no_expectation",
                      "the build batch recorded no expected core commit — nothing to compare against",
                      expected: expected, actual: actual, remote: remote)
        end

        # An expectation that is not a commit identity AT ALL (a branch name, a
        # tag, junk) says nothing this gate can weigh against a sha. Same
        # posture as System::CoreMirrorPreflight's STATE_UNUSABLE_EXPECTATION:
        # not measured, so not refused on.
        #
        # A short-but-sha-like expectation is NOT handled here — it is still
        # conclusive when its prefix DISAGREES with the artifact, so it is
        # decided at the comparison below.
        unless sha_like?(expected)
          return unusable(module_name, expected, actual, remote,
                          "#{expected.inspect} is not a commit identity")
        end

        unless enabled?
          return pass("disabled", "#{ENABLED_SETTING} is disabled",
                      expected: expected, actual: actual, remote: remote)
        end

        if actual.blank?
          return refuse("missing",
                        "#{module_name} is built on a clone of core, but the artifact carries no " \
                        "#{SHA_ANNOTATION} annotation — the build could not be shown to contain " \
                        "the expected core #{short(expected)}",
                        expected: expected, actual: actual, remote: remote)
        end

        if actual.casecmp?(UNRESOLVED_SHA)
          return refuse("unresolved",
                        "the builder could not resolve which core commit it cloned (recorded " \
                        "`#{UNRESOLVED_SHA}`#{remote_suffix(remote)}); expected #{short(expected)}",
                        expected: expected, actual: actual, remote: remote)
        end

        unless sha_like?(actual)
          return refuse("malformed",
                        "#{SHA_ANNOTATION} is #{actual.inspect}, which is not a commit sha" \
                        "#{remote_suffix(remote)}; expected #{short(expected)}",
                        expected: expected, actual: actual, remote: remote)
        end

        unless same_commit?(actual, expected)
          # Prefix AGREEMENT that is merely too short to be an identity is not
          # evidence of a different commit — it is an inconclusive comparison,
          # and refusing on it rejected four consecutive good builds on
          # 2026-08-24/25 (a core-SOURCED batch expects its own head_sha, and
          # this platform dispatches the short tag form). Prefix DISAGREEMENT is
          # conclusive at any length, so the stale-mirror artifact this gate
          # exists to stop — which carries an unrelated sha — still refuses.
          if prefix_agrees?(actual, expected)
            return unusable(module_name, expected, actual, remote,
                            "the expected core ref #{expected.inspect} agrees with the artifact as far " \
                            "as it goes, but is too short (needs #{MIN_ABBREV_LENGTH}+ hex chars) to " \
                            "identify a commit")
          end

          shown_actual, shown_expected = contrast(actual, expected)
          return refuse("mismatch",
                        "built from core #{shown_actual}#{remote_suffix(remote)}, but this batch " \
                        "expected core #{shown_expected}",
                        expected: expected, actual: actual, remote: remote)
        end

        pass("match", "built from the expected core #{short(actual)}",
             expected: expected, actual: actual, remote: remote)
      end

      # The verdict for a caller with no native-build context at all — the Gitea
      # webhook and the CI-direct REST publish. Those paths have no batch and no
      # expectation, and must be byte-for-byte unaffected by this gate.
      def inert
        Verdict.new(promotable: true, state: "not_native",
                    reason: "not a native build — no core provenance context")
      end

      def class_b?(module_name)
        CLASS_B_PARENT_MODULES.include?(module_name.to_s)
      end

      # Default ON. A gate an operator has to remember to switch on is not a
      # gate. The switch exists because the failure mode is "the fleet stays on
      # the previous version" — recoverable, but an operator mid-incident needs
      # to be able to override it without a deploy, the same way
      # system.module_publish.min_artifact_bytes is tunable.
      def enabled?
        setting_enabled?(ENABLED_SETTING)
      end

      # Reads a default-ON operator switch out of SiteSetting. Public and
      # parameterised because the core-provenance protection now has TWO
      # switches — this promote gate and System::CoreMirrorPreflight's
      # dispatch-time refusal — and the `0`/`false`/`off` handling below is
      # exactly the kind of care that rots when it is written twice.
      def setting_enabled?(name)
        raw = ::SiteSetting.get(name)
        return true if raw.nil?
        # SiteSetting returns a real Integer for setting_type "integer", and 0 is
        # TRUTHY in Ruby — an operator who writes 0 meaning "off" would otherwise
        # get a switch that silently does nothing.
        return false if raw == false || raw == 0
        return true unless raw.is_a?(String)

        value = raw.strip.downcase
        return true if value.empty?

        !%w[false 0 off no disabled].include?(value)
      rescue StandardError
        true
      end

      # Public for System::CoreMirrorPreflight, which compares the SAME two
      # kinds of value (a resolved core tip against a recorded expectation) and
      # must answer "is this the same commit" the same way — including the
      # abbreviation rules below, so the two protections can never disagree
      # about what "diverged" means.
      #
      # Those rules are git's own. Either side may legitimately arrive
      # abbreviated (a webhook head_sha, an operator-supplied ref), and refusing
      # a correct build because one side was short is a false positive — a gate
      # that cries wolf is a gate an operator turns off. A prefix shorter than
      # MIN_ABBREV_LENGTH is rejected rather than trusted.
      def same_commit?(actual, expected)
        a = actual.to_s.downcase
        b = expected.to_s.downcase
        return true if a == b
        return false unless sha_like?(b)

        long, short = a.length >= b.length ? [ a, b ] : [ b, a ]
        return false if short.length < MIN_ABBREV_LENGTH

        long.start_with?(short)
      end

      def sha_like?(value)
        SHA_PATTERN.match?(value.to_s.downcase)
      end

      def short(sha)
        sha.to_s[0, 7].presence || "(none)"
      end

      # Is this value usable as a commit IDENTITY — something a comparison can
      # return a meaningful answer about? Public and defined HERE because
      # System::CoreMirrorPreflight asks the same question of the same values;
      # a rule defined twice is a rule that drifts, and these two protections
      # disagreeing about what counts as an expectation is precisely how the
      # promote gate came to refuse builds the preflight had waved through.
      def usable_expectation?(value)
        sha_like?(value) && value.to_s.length >= MIN_ABBREV_LENGTH
      end

      # Do the two agree as far as the shorter one goes? Distinct from
      # #same_commit?, which additionally demands that the shorter side be long
      # enough to constitute an identity. This answers only "is there any
      # disagreement here", which is what separates an inconclusive comparison
      # from a conclusive refusal.
      def prefix_agrees?(actual, expected)
        a = actual.to_s.downcase
        b = expected.to_s.downcase
        return false if a.empty? || b.empty?

        long, short = a.length >= b.length ? [ a, b ] : [ b, a ]
        long.start_with?(short)
      end

      # Render two shas so a reader can SEE the difference between them.
      #
      # #short truncates to 7, so a refusal comparing a 9-char expectation
      # against the full 40-char annotation printed "built from core b01d7c4
      # ... but this batch expected core b01d7c4" — the same string twice. The
      # message destroyed the one distinction it existed to convey, and four
      # deploys were hand-repointed around this gate rather than diagnosed.
      #
      # Show whichever is longer: the first differing character plus context,
      # or — when one is a prefix of the other, where there IS no differing
      # character — both in full, since the LENGTH is then the whole story.
      def contrast(a, b)
        a = a.to_s
        b = b.to_s
        idx = (0...[ a.length, b.length ].min).find { |i| a[i] != b[i] }
        return [ a, b ] if idx.nil?

        width = [ idx + 4, 7 ].max
        [ a[0, width], b[0, width] ]
      end

      private

      def pass(state, reason, expected:, actual:, remote:)
        Verdict.new(promotable: true, state: state, reason: reason,
                    expected_sha: expected.presence, actual_sha: actual.presence, actual_remote: remote)
      end

      # Not a pass in the sense of "this artifact was checked and is fine" — a
      # pass in the sense of "this gate had nothing to weigh, and an unarmed
      # gate must not masquerade as a refusal". Logged at warn precisely because
      # the promotion proceeds: silence here would be the "protection that looks
      # present and is not" this class was written to avoid.
      def unusable(module_name, expected, actual, remote, detail)
        Rails.logger.warn(
          "[CoreProvenanceGate] #{module_name}: #{detail} — core provenance was NOT CHECKED for this " \
          "artifact. Nothing was measured; this is not a clean bill of health."
        )
        pass("unusable_expectation",
             "#{detail} — core provenance was NOT CHECKED",
             expected: expected, actual: actual, remote: remote)
      end

      def refuse(state, reason, expected:, actual:, remote:)
        Verdict.new(promotable: false, state: state, reason: reason,
                    expected_sha: expected.presence, actual_sha: actual.presence, actual_remote: remote)
      end

      # The 2026-08-15 incident was a RIGHT BRANCH NAME on a STALE MIRROR —
      # github.com and the Gitea both carried a `develop`, three days apart — so
      # the sha alone looked entirely plausible. An operator reading a refusal
      # needs the host.
      def remote_suffix(remote)
        remote.present? ? " (from #{remote})" : ""
      end
    end
  end
end
