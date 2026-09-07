# frozen_string_literal: true

module System
  module Fleet
    module Sensors
      # IMP-e840a570a371 — the oracle for "is the ACTIVE boot image capable of
      # what the code now assumes".
      #
      # BootImageDriftSensor answers a different question and answers it well:
      # does this node's booted image match the one active for its platform.
      # Nothing answered whether the active image is itself current. That gap
      # let a three-week-old image stand as the fleet's answer while the code
      # gained a hard dependency on kernel modules that image does not contain —
      # and every node reported NOT drifted the whole time, because they all
      # matched the stale pointer exactly. A fleet-wide capability gap read as
      # green, which is the platform's own oracle rule violated one level up:
      # absence of an observation is NOT MEASURED, never healthy.
      #
      # THE COMPARISON IS REACHABILITY, NOT EQUALITY, and an earlier draft of
      # this sensor got that wrong in a way that would have made it useless.
      # The image build triggers on a TAG push and records `github.sha` — the
      # commit the tag points at — while the question here is about the last
      # commit that touched the image-defining paths. Those two shas are equal
      # only when the operator happened to cut the tag at exactly that commit,
      # so an equality test fires immediately after a fresh, fully current
      # image is promoted and never stops. What actually matters is whether the
      # head of those paths is CONTAINED in the active build: compare
      # active...head and read the commit list. Empty means head is an ancestor
      # of the active image — current. Non-empty is the gap, and its size is
      # the answer to "behind by how much".
      #
      # THE ACTIVE IMAGE IS THE PLATFORM POINTER, not "the newest published
      # row". NodePlatform#disk_image_git_sha is what the boot-image byte
      # server, the upgrade dispatcher, the retention service and
      # BootImageDriftSensor all read, and it is what a rollback moves. The
      # publications table routinely holds several `published` rows at once
      # (retention keeps disk_image_retention_count of them, default 3), so
      # after a rollback the newest published row is an image nothing boots.
      # Reading the pointer also means the two boot-image sensors agree about
      # which image is the fleet's answer.
      #
      # VISIBILITY-ONLY, and that is a safety property rather than a phase.
      # Bound observation-only in DecisionEngine (skill: nil, action_category
      # "system.observation"), with no applier keyed on either kind, so the
      # safety is structural rather than policy-dependent: even an operator who
      # made that category auto_approve would find nothing to run. A sensor
      # that could roll an image would be the control plane re-imaging the
      # substrate it runs on — a self-management hazard under INV-1. Cutting
      # the image tag stays an operator action, out of band.
      class BootImageStalenessSensor < BaseSensor
        # Which repository feeds the image, as "owner/name". No default: this is
        # deployment-local (a fork, a mirror and the canonical repo are all
        # legitimate answers) and a guessed one would silently measure the wrong
        # tree. Unset is reported as NOT MEASURED, never as healthy.
        SOURCE_REPO_SETTING   = "system.disk_image.source_repo"
        SOURCE_BRANCH_SETTING = "system.disk_image.source_branch"
        # Comma-separated override for the paths below.
        SOURCE_PATHS_SETTING  = "system.disk_image.source_paths"

        DEFAULT_BRANCH = "develop"

        # Structural, not deployment-local, so a constant rather than a setting:
        # these are where the image's content is decided in THIS repo layout.
        # `initramfs` covers the module force-include list, the build script and
        # the modules.d fragments; the workflow file covers the build inputs.
        DEFAULT_PATHS = [
          "initramfs",
          ".gitea/workflows/build-disk-image.yaml"
        ].freeze

        # Cap on the commit list carried in the payload. The COUNT is always
        # exact; only the enumeration is truncated, because a signal payload is
        # read by humans and a 400-commit array is not read at all.
        MAX_LISTED_COMMITS = 20

        # This is the first sensor in the sense pass that makes an OUTBOUND HTTP
        # call, and sensors run serially — so an un-throttled version would add
        # its latency to every 60s tick for every other sensor, and would spend
        # ~2,880 Gitea requests a day to re-answer a question whose answer
        # changes when someone commits. Image staleness is a slow-moving fact;
        # a 30-minute cadence loses nothing and costs ~96 requests a day.
        CHECK_INTERVAL_SECONDS = 1800

        # Only Gitea's commits endpoint supports the `path` filter this sensor's
        # whole design rests on. The GitHub and GitLab clients accept the option
        # and DISCARD it, answering with the branch tip instead — a well-formed
        # response to a different question, which would make this sensor emit
        # on every commit to anything, forever. Refusing to measure is the
        # honest answer there, and it surfaces as not_measured.
        SUPPORTED_PROVIDER_TYPES = %w[gitea].freeze

        def self.default_thresholds
          { "check_interval_seconds" => CHECK_INTERVAL_SECONDS }
        end

        def sense
          return [] unless due_for_check?

          repo = source_repository
          return [ not_measured("source_repository_unset") ] if repo.nil?

          client = client_for(repo)
          return [ not_measured("no_usable_git_client", repo: repo) ] if client.nil?

          head = head_commit_for_image_paths(client, repo)
          return [ not_measured("head_lookup_failed", repo: repo) ] if head.nil?

          record_check!
          platforms.filter_map { |platform| assess(platform, head, client, repo) }
        end

        private

        def platforms
          ::System::NodePlatform.where(account_id: account.id, enabled: true)
        end

        # One platform's verdict: stale, not measured, or nothing.
        def assess(platform, head, client, repo)
          active = platform.disk_image_git_sha.to_s
          # No image has ever been promoted for this platform. That is a
          # different fact from "the image is stale" and this sensor is not the
          # one that reports it.
          return nil if active.blank?
          return nil if active == head["sha"] # trivially current; skip the call

          gap = commits_between(client, repo, active, head["sha"])
          return not_measured("compare_failed", repo: repo, platform: platform) if gap.nil?
          return nil if gap.empty? # head is reachable from the active build

          stale_signal(platform, active, head, gap, repo)
        end

        def stale_signal(platform, active, head, gap, repo)
          signal(
            kind: "system.boot_image_stale",
            severity: :medium,
            payload: {
              # Top-level so a reader can group by platform without unwrapping.
              "platform_id" => platform.id,
              "platform_name" => platform.name,
              "active_git_sha" => active,
              "head_git_sha" => head["sha"],
              "head_path" => head["path"],
              "head_committed_at" => head["committed_at"],
              "source_repo" => "#{repo.owner}/#{repo.name}",
              "source_branch" => source_branch,
              "source_paths" => source_paths,
              "commits_behind" => gap.size,
              "commits" => gap.first(MAX_LISTED_COMMITS).map { |c| summarize_commit(c) },
              "truncated" => gap.size > MAX_LISTED_COMMITS,
              "summary" => "the active boot image for #{platform.name} was built before " \
                           "#{gap.size} commit(s) to #{source_paths.join(', ')}",
              "remediation_action" => nil
            },
            # Deduped per PLATFORM, not per (platform, head). Including the head
            # sha would re-notify on every commit that touches initramfs, which
            # turns a standing condition into a stream and trains the reader to
            # ignore it. The payload carries the live pair either way.
            fingerprint: "boot_image_stale:#{platform.id}"
          )
        end

        # The finding's own thesis, applied to itself: a question this sensor
        # could not answer must not be reported as a healthy fleet. Every exit
        # above that cannot reach a verdict lands here rather than returning [].
        # Follows the shape of system.sdwan_apply_not_measured.
        def not_measured(reason, repo: nil, platform: nil)
          signal(
            kind: "system.boot_image_staleness_not_measured",
            severity: :medium,
            payload: {
              "reason" => reason,
              "platform_id" => platform&.id,
              "source_repo" => repo && "#{repo.owner}/#{repo.name}",
              "source_setting" => SOURCE_REPO_SETTING,
              "summary" => "boot-image staleness is UNKNOWN, not healthy (#{reason})",
              "remediation_action" => nil
            },
            fingerprint: "boot_image_staleness_not_measured:#{account.id}:#{reason}"
          )
        end

        # nil means "could not tell" — deliberately distinct from [] ("nothing
        # between"), because collapsing the two is how a failed lookup would
        # read as a current image. This is why the comparison is load-bearing
        # here rather than decoration.
        def commits_between(client, repo, base, head_sha)
          comparison = client.compare_commits(repo.owner, repo.name, base, head_sha)
          raw = comparison.is_a?(Hash) ? (comparison[:commits] || comparison["commits"]) : nil
          Array(raw)
        rescue StandardError => e
          Rails.logger.warn("[#{self.class.name}] compare #{base}...#{head_sha}: #{e.class}: #{e.message}")
          nil
        end

        def summarize_commit(commit)
          sha = commit[:sha] || commit["sha"]
          message = commit[:message] || commit["message"] ||
                    commit.dig(:commit, :message) || commit.dig("commit", "message")
          { "sha" => sha.to_s[0, 12], "message" => message.to_s.lines.first.to_s.strip }
        end

        # Newest commit across the watched paths. One request per path, and the
        # request does the filtering server-side (`path` on Gitea's commits
        # endpoint) — the alternative is listing commits and asking for each
        # one's file list, a request per commit, since neither the compare nor
        # the list endpoint carries file names.
        #
        # nil (not []) when NO path could be resolved, so the caller reports
        # not_measured rather than silence.
        def head_commit_for_image_paths(client, repo)
          heads = source_paths.filter_map { |path| newest_commit(client, repo, path) }
          return nil if heads.empty?

          # Parsed, not compared as strings: Gitea emits RFC3339 preserving each
          # commit's own UTC offset, so a lexicographic max across two paths
          # authored in different zones picks the older head.
          heads.max_by { |c| parsed_time(c["committed_at"]) }
        end

        def newest_commit(client, repo, path)
          raw = client.list_commits(
            repo.owner, repo.name,
            sha: source_branch, path: path, per_page: 1
          )
          commit = Array(raw).first
          return nil if commit.blank?

          sha = (commit["sha"] || commit[:sha]).to_s
          return nil if sha.blank?

          {
            "sha" => sha,
            "committed_at" => commit.dig("commit", "committer", "date").to_s,
            "path" => path
          }
        rescue StandardError => e
          Rails.logger.warn("[#{self.class.name}] head lookup for #{path}: #{e.class}: #{e.message}")
          nil
        end

        def parsed_time(value)
          Time.zone.parse(value.to_s) || Time.zone.at(0)
        rescue StandardError
          Time.zone.at(0)
        end

        # NOTE: SiteSetting is GLOBAL, not account-scoped, while this sensor
        # iterates account-scoped platforms. Correct in core mode (single
        # account) and worth knowing before this runs multi-tenant.
        def source_repository
          full_name = ::SiteSetting.get(SOURCE_REPO_SETTING).to_s.strip
          return nil if full_name.blank?

          owner, name = full_name.split("/", 2)
          return nil if owner.blank? || name.blank?

          ::Devops::GitRepository.find_by(account_id: account.id, owner: owner, name: name)
        end

        def source_branch
          ::SiteSetting.get(SOURCE_BRANCH_SETTING).to_s.strip.presence || DEFAULT_BRANCH
        end

        def source_paths
          configured = ::SiteSetting.get(SOURCE_PATHS_SETTING).to_s.split(",").map(&:strip).reject(&:blank?)
          configured.presence || DEFAULT_PATHS
        end

        def client_for(repo)
          credential = repo.git_provider_credential
          return nil if credential.nil?
          return nil if credential.respond_to?(:can_be_used?) && !credential.can_be_used?
          return nil unless SUPPORTED_PROVIDER_TYPES.include?(credential.provider&.provider_type.to_s)

          ::Devops::Git::ApiClient.for(credential)
        rescue StandardError => e
          Rails.logger.warn("[#{self.class.name}] no usable git client for #{repo.id}: #{e.class}: #{e.message}")
          nil
        end

        # Throttle state lives in the cache, deliberately NOT in the account's
        # SensorConfig row. That row is the OPERATOR's threshold-override store,
        # read by BaseSensor.resolved_thresholds and reported by the MCP config
        # verb; writing a sensor-owned runtime stamp into it would surface
        # `last_checked_at` as though it were a tunable and put a sensor write
        # inside operator-owned config. BaseSensor's one sanctioned sensor write
        # is persisting a SAMPLE, which this is not.
        #
        # Best-effort by construction: a cold or unavailable cache means the
        # check simply runs, which is the safe direction — the failure mode is
        # an extra pair of API calls, never a missed measurement. An instance
        # variable would not work at all, since the sense pass builds a fresh
        # sensor per tick.
        def check_stamp_key
          "fleet:#{self.class.sensor_key}:last_checked_at:#{account.id}"
        end

        def due_for_check?
          last = Rails.cache.read(check_stamp_key)
          return true if last.blank?

          parsed_time(last) <= threshold("check_interval_seconds").to_i.seconds.ago
        rescue StandardError
          true
        end

        def record_check!
          interval = threshold("check_interval_seconds").to_i
          Rails.cache.write(check_stamp_key, Time.current.iso8601, expires_in: (interval * 2).seconds)
        rescue StandardError => e
          Rails.logger.warn("[#{self.class.name}] could not record check stamp: #{e.class}: #{e.message}")
        end
      end
    end
  end
end
