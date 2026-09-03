# frozen_string_literal: true

module System
  class CveExposure < BaseRecord
    self.table_name = "system_cve_exposures"

    # `suspected` (IMP-7bba0413c36a) is a keyword-only match: the CVE's package
    # NAME was found in the module's name/repo and nothing else — no version,
    # so no evidence the module ships the vulnerable code. It is NOT an
    # exposure: every count (system_get_cve_exposure, system_cve_triage) and
    # every autonomy lane (CvePublishedSensor, CriticalUpgradeAvailableSensor,
    # AgedExposureEscalator, the orchestrator's transition) leaves it out. It
    # becomes `open` only when an SBOM match confirms it (#record_match).
    #
    # The exposure COUNTS key on evidence rather than on this state (see
    # .unconfirmed): the same task's migration resolved the pre-existing
    # keyword-only rows, and a `resolved` row still appears in
    # system_get_cve_exposure's per-module `states` breakdown.
    #
    # ONE reader does not honour the exclusion: System::Fleet::Sensors::
    # PackageDriftSensor#cve_flagged? tests `CveExposure...exists?` with no
    # state predicate at all, so any row — suspected or resolved — still
    # raises a package-drift signal's severity. That is pre-existing (keyword
    # rows were `open` before this change, and flagged then too) and left
    # alone here; governance/policy_declarations.rb already describes it as
    # reading "an open CveExposure", which it does not.
    STATES = %w[open suspected remediating resolved wont_fix].freeze

    # How the row was matched (ExposureCalculator stamps it):
    #   sbom    — ecosystem-aware version-range match against an ingested SBOM
    #             (VersionMatcher): version evidence.
    #   keyword — the v0 name-overlap fallback: no version evidence.
    MATCH_METHODS = %w[sbom keyword].freeze

    # The resolution_note the IMP-7bba0413c36a migration wrote on keyword-only
    # rows that were open at the time; mirrored there as a literal.
    KEYWORD_FALSE_POSITIVE_NOTE = "keyword-fallback false positive (no version evidence)"

    belongs_to :cve, class_name: "System::Cve", foreign_key: :cve_id
    belongs_to :node_module_version, class_name: "System::NodeModuleVersion",
               foreign_key: :node_module_version_id

    validates :package_name, presence: true
    validates :state, inclusion: { in: STATES }
    validates :match_method, inclusion: { in: MATCH_METHODS }
    validate :suspected_requires_keyword_match

    before_validation :infer_match_method, on: :create

    attribute :metadata, :json, default: -> { {} }

    scope :open,         -> { where(state: "open") }
    scope :suspected,    -> { where(state: "suspected") }
    scope :remediating,  -> { where(state: "remediating") }
    scope :resolved,     -> { where(state: "resolved") }
    # Deliberately NOT including `suspected`: this is the scope the autonomy
    # lanes read (CriticalUpgradeAvailableSensor, the orchestrator's
    # transition), and a suspicion is not theirs to act on.
    scope :unresolved,   -> { where(state: %w[open remediating]) }

    # Evidence, not state. `unconfirmed` is the set the exposure counts leave
    # out: a keyword row carries no version evidence in ANY state, and after
    # this task's migration the rows it was filed about are `resolved`, not
    # `suspected` — keying the exclusion on the state alone would still have
    # counted them (system_get_cve_exposure reports resolved rows).
    scope :version_confirmed, -> { where(match_method: "sbom") }
    scope :unconfirmed,       -> { where(match_method: "keyword") }

    # Apply one calculator match to this row (new or found) without saving, so
    # the caller can count created/updated. The rules:
    #   - a NEW row is `open` for an sbom match and `suspected` for a keyword
    #     match;
    #   - an EXISTING row that an sbom match CONFIRMS flips to `open`, and its
    #     detected_at is re-stamped: the confirmation is the detection as far
    #     as CvePublishedSensor's fresh-detection window is concerned (a
    #     suspicion minted a month ago must not land straight in the aged lane
    #     the moment it becomes real). Two rows are confirmable — a
    #     `suspected` one, and one this task's migration RESOLVED for lack of
    #     version evidence (#keyword_false_positive?). The migration's
    #     resolution is a suppression, not a decision: the evidence it was
    #     resolved for lacking has now arrived, so the row must come back or a
    #     real exposure stays hidden forever;
    #   - an OPERATOR's resolution is a decision and survives: a row resolved
    #     with any other note keeps its state, gaining only the evidence
    #     (match_method / package_version). So does open, remediating and
    #     wont_fix;
    #   - version evidence never downgrades: a keyword re-match on an sbom row
    #     leaves it untouched (the caller sees no change), and a resolved
    #     false positive stays resolved on a keyword re-match.
    def record_match(match_method:, package_version:)
      method = match_method.to_s
      return self if persisted? && sbom_matched? && method == "keyword"

      confirmable = suspected? || keyword_false_positive?

      self.match_method = method
      self.package_version = package_version

      if new_record?
        self.state = method == "sbom" ? "open" : "suspected"
      elsif method == "sbom" && confirmable
        self.state = "open"
        self.detected_at = Time.current
        self.resolved_at = nil
        self.resolution_note = nil
      end

      self.detected_at ||= Time.current
      self
    end

    # Resolved by the IMP-7bba0413c36a migration (or the same lane) purely for
    # want of version evidence — matched on the note it writes, so an
    # operator's own resolution of a keyword row is never re-opened.
    def keyword_false_positive?
      state == "resolved" && resolution_note == KEYWORD_FALSE_POSITIVE_NOTE
    end

    # Tracked by hand: an explicit "keyword" equals the column default, so
    # dirty tracking cannot tell it from "never said" — and the difference is
    # exactly what #infer_match_method needs.
    def match_method=(value)
      @match_method_assigned = true
      super
    end

    def suspected?
      state == "suspected"
    end

    def sbom_matched?
      match_method == "sbom"
    end

    def resolve!(note: nil)
      update!(state: "resolved", resolved_at: Time.current, resolution_note: note)
    end

    def remediating!
      update!(state: "remediating")
    end

    private

    # A row created without an explicit match_method (the column default is
    # `keyword`) is read the way the IMP-7bba0413c36a backfill read the rows
    # that predate the column: a version is the SBOM matcher's evidence, a
    # blank one is the fallback's signature. An explicit assignment wins.
    def infer_match_method
      return if @match_method_assigned
      self.match_method = "sbom" if package_version.present?
    end

    def suspected_requires_keyword_match
      return unless suspected? && match_method != "keyword"
      errors.add(:state, "suspected is only for a keyword match — an sbom match carries version evidence and is open")
    end
  end
end
