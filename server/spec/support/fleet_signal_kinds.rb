# frozen_string_literal: true

# Shared derivation of the fleet sensors' emitted signal-kind set.
#
# EXTRACTED, NOT REWRITTEN. The parser body below is the one IMP-e839dd0ffc05
# committed inside spec/docs/fleet_sensors_signal_kinds_spec.rb (0e40b232);
# IMP-e491c01f5c01 needed the same set for a docs-TREE guard and a second
# hand-rolled copy is exactly how the two would drift apart. The three shapes it
# resolves are load-bearing and a naive `kind: "..."` scan gets each wrong:
#
#   * a TERNARY   — sdwan_bgp_session_health_sensor.rb:108-109 puts the two
#                   literals after `kind: unattributable ?`;
#   * a CONSTANT  — federation_peer_liveness_sensor.rb:43 `SIGNAL_KIND = "..."`;
#   * a READ      — honeypot_access_sensor.rb:21 `.where(account:, kind:)` is a
#                   query over the event log, NOT an emit, and counting it
#                   inflates the set by one.
#
# A literal grep gives 40; the answer is 42.
#
# NOTE for whoever touches fleet_sensors_signal_kinds_spec.rb next: that file
# still carries its own inline copy of this parser. It was NOT switched over
# here because another agent held the file at the time this was written.
# Collapsing it onto this module is a clean follow-up.
module FleetSignalKinds
  SENSORS_DIR = "server/app/services/system/fleet/sensors"

  # Every signal kind the registered fleet sensors can emit, sorted.
  #
  # Raises rather than returning a short list: every oracle built on this set is
  # an equality, and an equality against a silently-truncated set is green for
  # the wrong reason.
  def self.emitted(ext_root)
    files = Dir[File.join(ext_root, SENSORS_DIR, "*.rb")]
              .reject { |p| File.basename(p) == "base_sensor.rb" }
    raise "no sensor sources found under #{SENSORS_DIR} — every oracle would be vacuous" if files.empty?

    per_file = files.to_h do |path|
      src = File.read(path)
      # Only SIGNAL_KIND-style constants. A blanket `CONST = "system.…"` scan
      # would also pick up boot_lkg_arm_sensor.rb's `SETTING_PREFIX =
      # "system.boot_lkg"`, silently adding a SiteSetting prefix to the set.
      consts = src.scan(/^\s*([A-Z][A-Z0-9_]*(?:SIGNAL|KIND)[A-Z0-9_]*)\s*=\s*"(system\.[a-z0-9_.]+)"/).to_h
      found = []
      src.to_enum(:scan, /\bkind:/).each do
        off = Regexp.last_match.begin(0)
        # Skip QUERY calls. Keyed on the nearest preceding call name rather than
        # a same-line `where(` test, so a read wrapped across lines is still
        # excluded. Stated as an exclusion rather than a `signal(`-only
        # allowlist because gitops_drift_sensor.rb:44 builds its signal as a
        # bare Hash literal with no builder call in front of it at all.
        caller_name = src[[ off - 400, 0 ].max...off].scan(/\b([a-z_]+)\(/).last&.first
        next if caller_name&.match?(/\A(where|find_by|exists|pluck|count|select|order)\z/)

        region = src[off, 400].split(/\n\s*[a-z_]+:\s/, 2).first
        found.concat(region.scan(/"(system\.[a-z0-9_.]+)"/).flatten)
        found.concat(region.scan(/\b([A-Z][A-Z0-9_]{2,})\b/).flatten.filter_map { |c| consts[c] })
      end
      [ path, found.uniq ]
    end

    # PER-FILE non-vacuity: a bare total floor lets the parser lose every kind
    # of one sensor and stay green on the strength of the other thirty.
    silent = per_file.select { |_, found| found.empty? }.keys.map { |p| File.basename(p) }
    raise "parsed no emitted kind from: #{silent.join(', ')} — the parser has stopped matching" if silent.any?

    per_file.values.flatten.uniq.sort
  end

  # The kinds IMP-e839dd0ffc05 (and the 2026-05-19 audit, for
  # system.runtime_docker_tls_rotate) withdrew: names that appeared in the docs
  # and that NO sensor emits. Kept listed rather than deleted so an operator who
  # bound a policy to one can still find out what happened to it.
  #
  # `sdwan.hub_unreachable` was added by IMP-e491c01f5c01. It is the reason this
  # list is a LIST and not a closed set: it stood two files from a name the
  # earlier enumeration did correct, in the same runbook this task edited, and
  # neither the earlier grep nor the first draft of the tree guard saw it
  # (`sdwan_reachability_sensor.rb:65,87` emit `system.sdwan_hub_unreachable`).
  WITHDRAWN = %w[
    cert.expired cert.expiring cert.rotated
    config.drift_detected config.drift_resolved
    gitops.drift_detected gitops.drift_resolved
    honeypot.access honeypot.access_attempted honeypot.access_blocked
    instance.recovered instance.silent
    module.drift_detected module.drift_resolved
    project.cost_breach project.drift project.slo_violation
    sdwan.bgp_recovered sdwan.bgp_unhealthy
    sdwan.peer_drift sdwan.peer_drift_detected sdwan.peer_drift_resolved
    sdwan.vip_holder_recovered sdwan.vip_holder_silent
    sdwan.hub_unreachable
    slo.recovered slo.violated
    system.instance_state_drift
    system.runtime_docker_tls_rotate
  ].freeze

  # Whole-token match. The boundaries matter in BOTH directions:
  #   * `gitops.drift_detected` must NOT match inside the real, two-dot
  #     `system.gitops.drift_detected` — the leading `.` guard is what stops it;
  #   * `honeypot.access` must not match inside `honeypot.access_attempted`.
  #
  # The trailing guard is NOT a flat `(?![a-z0-9_.])`. That was the first
  # version and it had a hole found in review: because `.` was in the class, a
  # token at the END OF A SENTENCE was exempt — "the sensor fires
  # instance.silent." passed while "…fires instance.silent when quiet" failed.
  # Ordinary English prose defeated the whole containment oracle. The dot is
  # only disqualifying when a NAME segment follows it, so the lookahead is
  # spelled out as "not another identifier char, and not a dot that begins a
  # further segment". `A-Z` is in both classes so `MYgitops.drift_detected` and
  # `gitops.drift_detectedX` do not match either.
  def self.mentions?(text, token)
    text.match?(/(?<![A-Za-z0-9_.])#{Regexp.escape(token)}(?![A-Za-z0-9_]|\.[A-Za-z0-9_])/)
  end
end
