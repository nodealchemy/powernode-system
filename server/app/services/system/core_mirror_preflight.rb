# frozen_string_literal: true

require "net/http"
require "uri"

module System
  # The DISPATCH-time half of the core-provenance protection: reads the PUBLIC
  # MIRROR's HEAD before any builder is leased, and lets the caller refuse a
  # Class-B batch that would be assembled from a mirror that has diverged from
  # core.
  #
  # WHY THIS EXISTS ALONGSIDE System::CoreProvenanceGate
  #
  # That gate is the backstop and it works: it compares the published
  # artifact's stamped `org.powernode.core_source_sha` against the batch's
  # recorded `expected_core_sha` and withholds promotion on a mismatch. But it
  # can only speak AFTER a full Class-B build has burned a leased ephemeral
  # builder and ~40 minutes of wall clock, because the stamped sha does not
  # exist until then.
  #
  # The asymmetry that makes an earlier answer cheap: the batch's expectation is
  # resolved from the AUTHORITATIVE remote (the Gitea core is pushed to, via
  # NativeModuleBuildOrchestrator#resolve_core_tip), while stage15.sh takes the
  # parent from the PUBLIC MIRROR (github.com/nodealchemy/powernode-platform),
  # which lags arbitrarily (three days on 2026-08-15; two outages). One of the
  # two tips is therefore already in hand at dispatch and the other is one HTTP
  # call away.
  #
  # THREE STATES, NOT TWO
  #
  #   agreed       — both tips read and they are the same commit. Proceed.
  #   diverged     — both tips read and they differ. REFUSE, naming both
  #                  remotes and both shas.
  #   undetermined — the mirror tip could NOT be read (outage, egress denial,
  #                  timeout, garbage body). NOT MEASURED: neither healthy nor
  #                  faulty. Proceed, and say out loud that the check did not
  #                  run — CoreProvenanceGate remains the backstop at promote.
  #
  # Collapsing `undetermined` into `diverged` would brick every Class-B build
  # fleet-wide on a network blip, which is a strictly worse failure than the one
  # this exists to prevent. ops-hub is default-deny egress, so "cannot reach
  # github.com" is a NORMAL reading here, not an exceptional one.
  #
  # THE PIN CHANGED THE QUESTION THIS ANSWERS — READ BEFORE TOUCHING THIS CLASS
  #
  # This check was written when stage15.sh cloned the parent with NO ref, so the
  # build landed on the mirror's HEAD and "is HEAD the expected commit" was
  # exactly the right question. stage15.sh now FETCHES the batch's
  # expected_core_sha directly (delivered as CORE_REF via ci_build_context) when
  # the platform supplies a full 40-hex one, so for those builds the question
  # that actually decides correctness is "does the mirror CONTAIN commit X",
  # not "is the mirror's HEAD equal to X".
  #
  # The two diverge in one direction: a mirror pushed PAST the expectation
  # contains the commit, so the pinned fetch would succeed and be correct — and
  # this check still reads `diverged` and REFUSES the dispatch. That refusal is
  # now conservative rather than necessary. It is left in place deliberately
  # (narrowing a live, default-ON protection is an operator decision, not a
  # side effect of adding the pin), but it is a known over-refusal and the
  # equality-not-ancestry limitation below is no longer justified by "the clone
  # is unpinned". The direction that still matters unconditionally is a mirror
  # BEHIND core: there the pinned fetch fails and the build goes red, and this
  # check turns that into a cheap refusal before a builder is leased.
  #
  # WHY HEAD, AND WHY THE GIT ENDPOINT RATHER THAN AN API
  #
  # HEAD is what the UNPINNED arm still lands on (a batch with no recorded
  # expectation, and the Gitea Actions path, which sends no CORE_REF), and it
  # is the cheapest proxy for "has the mirror caught up" for the pinned arm;
  # a named-branch lookup would answer a different question again.
  # `GET /<path>.git/info/refs?service=git-upload-pack` is the very endpoint
  # that clone begins with: no credential (the mirror is public — stage15.sh
  # deliberately omits PARENT_PAT for a github.com host), no provider-API shape
  # to keep in sync, no 60/hour unauthenticated API rate limit to trip on a
  # sweep loop, and it works unchanged if an operator repoints the mirror at a
  # different host.
  #
  # KNOWN LIMITATION, inherited deliberately from CoreProvenanceGate: the
  # comparison is EQUALITY, so it is blind to DIRECTION. A mirror that is BEHIND
  # core (the incident) and a mirror that is merely a few seconds AHEAD of a
  # deliberately-older rebuild both read as `diverged`. That is the safe
  # direction and the cost is bounded — nothing was built yet, the operator gets
  # a refusal naming both remotes, and pushing the mirror (or ENABLED_SETTING)
  # clears it. Turning this into an ancestry test needs a compare API call and
  # is out of scope here.
  #
  # NOT IN SCOPE: repointing the clone. Which remote stage15.sh clones from is
  # an operator decision; this only reports on the remote as it stands.
  class CoreMirrorPreflight
    # Default ON, same posture (and same reader) as the promote gate: a
    # protection an operator must remember to switch on is not a protection.
    ENABLED_SETTING = "system.module_build.core_mirror_preflight"

    # Where stage15.sh actually clones the parent from. These defaults are that
    # script's own defaults (POWERNODE_PARENT_HOST / POWERNODE_PARENT_PATH) —
    # the server never overrides them today, so the compiled-in pair IS what
    # every builder uses. Overridable so this keeps checking the RIGHT remote if
    # an operator ever moves the mirror.
    MIRROR_HOST_SETTING = "ci_core_mirror_host"
    MIRROR_PATH_SETTING = "ci_core_mirror_path"
    MIRROR_HOST_DEFAULT = "github.com"
    MIRROR_PATH_DEFAULT = "nodealchemy/powernode-platform"

    # dispatch! runs synchronously from the MCP tool, ModuleBuildTriggerService,
    # PackageClosureBuildBridge and CiRunnerLeaseSweepService — a sweep loop.
    # ONE call, hard-bounded at OPEN + READ, is the entire latency budget this
    # check is allowed. (Contrast the Gitea tip resolution it rides alongside:
    # two calls at 10s connect + 30s read each.)
    OPEN_TIMEOUT = 3
    READ_TIMEOUT = 5

    # A ref advertisement for this repo is tens of KB. Truncating the parse
    # keeps a pathological body from turning into pathological CPU; HEAD is the
    # FIRST ref advertised, so nothing that matters lives past the cut.
    MAX_ADVERTISEMENT_BYTES = 256 * 1024

    # pkt-line frames the advertisement as `<4-hex length><sha> HEAD\0<caps>`,
    # so the length prefix runs straight into the sha with no separator. The
    # match is anchored on the trailing " HEAD", which makes the 40 characters
    # it captures the sha and not a window shifted into the prefix.
    HEAD_REF_PATTERN = /([0-9a-f]{40})[ \t]+HEAD(?![-\w])/

    STATE_AGREED         = "agreed"
    STATE_DIVERGED       = "diverged"
    STATE_UNDETERMINED   = "undetermined"
    STATE_DISABLED       = "disabled"
    STATE_NO_EXPECTATION = "no_expectation"
    # An expectation exists but is not a commit identity this can compare
    # (a branch name, or an abbreviation too short to be an identity). NOT the
    # same fact as "no expectation", and emphatically not the same fact as
    # "diverged" — see #check.
    STATE_UNUSABLE_EXPECTATION = "unusable_expectation"

    Verdict = Struct.new(:state, :refuse, :reason, :expected_sha, :expected_repo,
                         :mirror_sha, :mirror_remote, keyword_init: true) do
      def refuse?
        !!refuse
      end

      def diverged?
        state == STATE_DIVERGED
      end

      def undetermined?
        state == STATE_UNDETERMINED
      end

      # What gets written onto the batch. Deliberately carries the STATE rather
      # than a boolean: "we looked and they matched" and "we could not look" are
      # different facts and an operator reading the batch afterwards must be
      # able to tell them apart.
      def to_metadata
        {
          "state"         => state,
          "reason"        => reason,
          "expected_sha"  => expected_sha,
          "expected_repo" => expected_repo,
          "mirror_sha"    => mirror_sha,
          "mirror_remote" => mirror_remote,
          "checked_at"    => Time.current.utc.iso8601
        }
      end
    end

    class << self
      # @param expected_sha [String, nil] the core commit this batch expects,
      #   as recorded by NativeModuleBuildOrchestrator#record_expected_core_ref!
      # @param expected_repo [String, nil] the remote that expectation came from
      #   ("<owner>/<repo>" on the authoritative Gitea) — for the refusal text
      # @return [Verdict] never raises; every failure mode is a state
      def check(expected_sha:, expected_repo: nil)
        expected = expected_sha.to_s.strip
        remote   = mirror_remote

        # Nothing to compare against. Same posture as the promote gate's
        # `no_expectation`: an absent expectation is never fabricated, and never
        # refused on.
        if expected.blank?
          return verdict(STATE_NO_EXPECTATION, refuse: false,
                         reason: "this batch recorded no expected core commit — there is nothing to " \
                                 "compare #{remote} against",
                         expected: expected, expected_repo: expected_repo, mirror_sha: nil, remote: remote)
        end

        # An expectation that is not a usable commit identity is NOT a
        # divergence. CoreProvenanceGate#same_commit? answers false for a branch
        # name and for any prefix under MIN_ABBREV_LENGTH, and a bare `unless
        # same_commit?` would read that false as "the mirror diverged" and
        # refuse — for input that never said anything about the mirror at all.
        # This is reachable: a core-SOURCED batch's expectation is its own
        # head_sha, and head_sha is validated for PRESENCE only, so the MCP
        # tool's free-string `head_sha:` (the 7-char tag form is this
        # platform's own convention) lands here. Refusing those would be a
        # false positive on operator input, which is exactly how a gate earns
        # being switched off.
        unless usable_expectation?(expected)
          return verdict(STATE_UNUSABLE_EXPECTATION, refuse: false,
                         reason: "this batch's expected core ref #{expected.inspect} is not a commit " \
                                 "identity this can compare against #{remote} — the mirror was not checked",
                         expected: expected, expected_repo: expected_repo, mirror_sha: nil, remote: remote)
        end

        unless enabled?
          return verdict(STATE_DISABLED, refuse: false,
                         reason: "#{ENABLED_SETTING} is disabled — the mirror was not checked",
                         expected: expected, expected_repo: expected_repo, mirror_sha: nil, remote: remote)
        end

        tip = resolve_mirror_tip

        if tip.blank?
          return verdict(STATE_UNDETERMINED, refuse: false,
                         reason: "the mirror-divergence check was NOT PERFORMED: #{remote}'s HEAD could " \
                                 "not be read. This is not measured — neither agreement nor divergence " \
                                 "— so the dispatch proceeds and the core-drift promote gate " \
                                 "(#{::System::CoreProvenanceGate::ENABLED_SETTING}) remains the backstop",
                         expected: expected, expected_repo: expected_repo, mirror_sha: nil, remote: remote)
        end

        if ::System::CoreProvenanceGate.same_commit?(tip, expected)
          return verdict(STATE_AGREED, refuse: false,
                         reason: "#{remote} is at the expected core #{short(tip)}",
                         expected: expected, expected_repo: expected_repo, mirror_sha: tip, remote: remote)
        end

        verdict(STATE_DIVERGED, refuse: true,
                reason: "the build would clone core from #{remote}, whose HEAD is #{short(tip)}, but this " \
                        "batch expects core #{short(expected)} from #{expected_repo.presence || 'the core repo'} " \
                        "— the mirror has DIVERGED from core, so the artifact would carry the wrong core. " \
                        "Push the mirror and re-plan, or set #{ENABLED_SETTING}=false to override",
                expected: expected, expected_repo: expected_repo, mirror_sha: tip, remote: remote)
      end

      # The remote's HEAD, or nil. NEVER raises and NEVER guesses: every failure
      # mode (no host/path configured, DNS, connect/read timeout, non-200, a
      # body with no HEAD in it) returns nil, which #check reads as
      # UNDETERMINED and refuses nothing on.
      def resolve_mirror_tip(host: mirror_host, path: mirror_path)
        return nil if host.blank? || path.blank?

        uri = URI.parse("https://#{host}/#{path}.git/info/refs?service=git-upload-pack")
        req = Net::HTTP::Get.new(uri.request_uri)
        # Ask for protocol v1 explicitly by asking for nothing: without a
        # Git-Protocol header the server answers with the v1 ref advertisement,
        # whose first entry is HEAD.
        req["User-Agent"] = "git/2.0 (powernode-core-mirror-preflight)"

        res = Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                              open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
          # Net::HTTP retries an idempotent request ONCE by default on a read
          # timeout / reset / SSL error, which would silently double the
          # latency budget above on the sweep path. One attempt, then NOT
          # MEASURED — a mirror we could not read in 8s is an answer.
          http.max_retries = 0
          http.request(req)
        end

        unless res.is_a?(Net::HTTPSuccess)
          Rails.logger.warn(
            "[CoreMirrorPreflight] #{host}/#{path} answered HTTP #{res.code} for its ref advertisement " \
            "— mirror tip NOT MEASURED"
          )
          return nil
        end

        # #parse_head_sha truncates, which bounds the REGEX; this bounds the
        # ALLOCATION, which truncation cannot. A declared body far past a ref
        # advertisement's size is not something to pull into the dispatch
        # path's memory to answer a question this cheap.
        declared = res.content_length
        if declared && declared > MAX_ADVERTISEMENT_BYTES
          Rails.logger.warn(
            "[CoreMirrorPreflight] #{host}/#{path} advertised #{declared} bytes of refs " \
            "(cap #{MAX_ADVERTISEMENT_BYTES}) — mirror tip NOT MEASURED"
          )
          return nil
        end

        sha = parse_head_sha(res.body)
        if sha.blank?
          Rails.logger.warn(
            "[CoreMirrorPreflight] #{host}/#{path} advertised no HEAD ref — mirror tip NOT MEASURED"
          )
        end
        sha
      rescue StandardError => e
        Rails.logger.warn(
          "[CoreMirrorPreflight] could not read #{host}/#{path}'s HEAD (#{e.class}: #{e.message}) " \
          "— mirror tip NOT MEASURED"
        )
        nil
      end

      def enabled?
        ::System::CoreProvenanceGate.setting_enabled?(ENABLED_SETTING)
      end

      # "<host>/<path>" — what an operator needs to see in a refusal. The
      # 2026-08-15 incident was the RIGHT branch name on the WRONG host, so a
      # sha without its host reads as entirely plausible.
      def mirror_remote
        "#{mirror_host}/#{mirror_path}"
      end

      def mirror_host
        setting(MIRROR_HOST_SETTING) || ENV["CI_CORE_MIRROR_HOST"].presence || MIRROR_HOST_DEFAULT
      end

      def mirror_path
        setting(MIRROR_PATH_SETTING) || ENV["CI_CORE_MIRROR_PATH"].presence || MIRROR_PATH_DEFAULT
      end

      private

      def setting(name)
        ::SiteSetting.get(name).presence
      rescue StandardError
        nil
      end

      # A commit identity this can actually compare: hex, and long enough that
      # a prefix match is an identity rather than a coincidence. Both rules are
      # CoreProvenanceGate's, so the two protections cannot disagree.
      # Delegated, not restated. The promote gate asks the same question of the
      # same values and now has its own arm for the answer; the two protections
      # disagreeing about what counts as an expectation is exactly how the
      # promote gate came to refuse builds this preflight had waved through.
      def usable_expectation?(value)
        ::System::CoreProvenanceGate.usable_expectation?(value)
      end

      def parse_head_sha(body)
        HEAD_REF_PATTERN.match(body.to_s[0, MAX_ADVERTISEMENT_BYTES].to_s)&.captures&.first
      end

      def short(sha)
        sha.to_s[0, 7].presence || "(none)"
      end

      def verdict(state, refuse:, reason:, expected:, expected_repo:, mirror_sha:, remote:)
        Verdict.new(state: state, refuse: refuse, reason: reason,
                    expected_sha: expected.presence, expected_repo: expected_repo.presence,
                    mirror_sha: mirror_sha.presence, mirror_remote: remote)
      end
    end
  end
end
