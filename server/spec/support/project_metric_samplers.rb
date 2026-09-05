# frozen_string_literal: true

# Shared derivation of the project-metric SAMPLER set.
#
# EXTRACTED, NOT REWRITTEN. The parser body below is the one
# spec/lint/project_metric_producer_census_spec.rb committed as
# `.wired_metrics`. A second oracle now needs the same set — the note census in
# spec/services/system/project_metrics_collector_unavailable_reason_spec.rb,
# which has to know which metrics genuinely have no sampler in order to assert
# that the "no telemetry backend wired" default reaches only those. A second
# hand-rolled copy is exactly how the two would drift apart, and this file
# follows the precedent spec/support/fleet_signal_kinds.rb set for the same
# problem on the sensor side.
#
# WHY A SOURCE SCAN RATHER THAN A RUNTIME PROBE. Which metrics have samplers is
# a property of `#sample_one`'s dispatch, and the arm that matters is its
# `else` — the fallthrough that produces an unavailable sample for anything the
# case statement does not name. There is nothing to call that reports "this
# metric reached the else arm"; the dispatch is the fact, so the dispatch is
# what gets read.
module ProjectMetricSamplers
  COLLECTOR_REL = "app/services/system/project_metrics_collector.rb"

  # SERVER_ROOT is this extension's server/ directory. `spec/support` is two
  # levels down from it — the census spec got this wrong once by joining
  # "server" onto a path that already contained it, and its vacuity guards are
  # what turned the mistake red instead of green.
  SERVER_ROOT = Pathname.new(__dir__).join("..", "..").cleanpath

  def self.read(rel)
    path = SERVER_ROOT.join(rel)
    raise "sampler-census target missing: #{rel}" unless path.exist?

    path.read
  end

  # The metrics `#sample_one` dispatches to a real sampler. Everything else
  # falls to its `else unavailable_sample(...)` arm.
  #
  # `when THROUGHPUT_METRIC` is resolved through the LIVE constant rather than
  # special-cased as a string, so renaming the constant cannot quietly drop a
  # metric out of the wired set.
  #
  # Raises rather than returning a short list: every oracle built on this set
  # is an equality or a subset, and both are green for the wrong reason against
  # a silently-collapsed scan.
  def self.wired
    body = read(COLLECTOR_REL)[/def sample_one\b.*?\n    end\n/m]
    raise "could not locate #sample_one — every sampler oracle would be vacuous" if body.nil?

    literals = body.scan(/when\s+"([a-z0-9_]+)"\s+then\s+sample_/).flatten
    consts   = body.scan(/when\s+([A-Z][A-Z0-9_]*)\s+then\s+sample_/).flatten.map do |const|
      ::System::ProjectMetricsCollector.const_get(const)
    end
    found = (literals + consts).uniq
    raise "the #sample_one scan matched #{found.size} samplers — it has collapsed" if found.size < 5

    found
  end

  # The metrics DECLARED in the collector's vocabulary but dispatched to no
  # sampler. These, and only these, are entitled to the collector's default
  # "no telemetry backend wired" note.
  def self.unproduced
    (::System::ProjectMetricsCollector::METRIC_TYPE_MAP.keys - wired).sort
  end
end
