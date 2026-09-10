# frozen_string_literal: true

module System
  module Fleet
    module Sensors
      # Detects a node platform whose most recent disk-image CI builds have
      # ALL failed — i.e. the last N publish attempts never landed a good
      # image, so the platform's fleet is running on a stale (or no) disk
      # image while CI keeps breaking. A single success anywhere in the
      # recent window breaks the streak; retired/purged rows (old history,
      # already cycled out) are excluded from consideration entirely so a
      # long-retired publication doesn't artificially extend the lookback.
      #
      # No auto-remediation exists — a broken CI pipeline needs an operator
      # to look at the build logs, not a retry — so this is a pure
      # observability signal (see DecisionEngine's
      # system.disk_image_publication_investigate binding).
      #
      # DK3 of the disk-image-CI restoration (see disk-image-ci-restore
      # branch DK1/DK2 for the registry-config + webhook chunks this
      # completes).
      class DiskImagePublicationFailureStreakSensor < BaseSensor
        # This sensor's rung of the account ladder (BaseSensor
        # .account_ladder_settings). The prefix + DEFAULT_<KEY> pair is what
        # makes the threshold DISCOVERABLE through system_get_sensor_config;
        # before it, the only way to learn this was tunable was to read the
        # source or FLEET_SENSORS.md.
        #
        # ACCOUNT_SETTING_PREFIX + "threshold" reproduces the key that is
        # already stored — "disk_image_failure_streak_threshold" — so nothing
        # an operator has configured moves.
        #
        # Deliberately NO SETTING_PREFIX: this threshold has never had a
        # deployment-wide SiteSetting rung, and adding one as a side effect of
        # making the sensor visible would change resolution for every account
        # that has not set it.
        ACCOUNT_SETTING_PREFIX = "disk_image_failure_streak"
        DEFAULT_THRESHOLD      = 3
        # Declared rather than clamped privately so the value the read verb
        # REPORTS as effective is the value this sensor USES.
        ACCOUNT_LADDER_BOUNDS  = { "threshold" => (1..20) }.freeze

        def sense
          account.system_node_platforms.find_each.flat_map do |platform|
            check_platform(platform)
          end
        end

        private

        def check_platform(platform)
          threshold = streak_threshold
          recent = platform.disk_image_publications
                            .where.not(status: %w[retired purged])
                            .order(created_at: :desc)
                            .limit(threshold)
                            .to_a

          return [] if recent.length < threshold
          return [] unless recent.all? { |pub| pub.status == "failed" }

          [
            signal(
              kind: "system.disk_image_publication_failure_streak",
              severity: :high,
              payload: {
                node_platform_id: platform.id,
                consecutive_failures: recent.length,
                last_publication_id: recent.first.id,
                oci_ref: recent.first.oci_ref
              },
              fingerprint: "disk_image_failure_streak:#{platform.id}"
            )
          ]
        end

        # Configurable per-account so a platform under active/flaky
        # development can tolerate a longer run before paging the operator
        # (feedback: no hardcoded numeric caps — resolve via Account#settings).
        #
        # Resolved through the shared seam rather than by hand, which changes
        # one edge: a stored 0 or a negative now reads as UNSET (the default 3)
        # instead of clamping up to 1. That is the rule every other sensor on
        # this ladder already applies, and "I cleared the field" should not
        # mean "alarm on the first failure".
        def streak_threshold
          @streak_threshold ||= self.class.resolved_account_ladder(account: account)["threshold"]
        end
      end
    end
  end
end
