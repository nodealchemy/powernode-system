# frozen_string_literal: true

require "rails_helper"
require "pathname"

# IMP-0ddfd8a60032 — the census of everything that decides a System::Provider
# row's provider_type.
#
# WHY THIS EXISTS. APO-7 (4c04e50f) established that a provider type whose
# adapter SDK gem is not bundled in this build must be refused AT THE WRITE,
# because every adapter call on such a row fails later with a bare NameError
# that reaches an MCP caller as -32603 rather than as a refusal it can act on.
# APO-7 guarded four doors. It described them as the doors. A follow-up
# (35b7ab3e) found a FIFTH — the credential POST minting a provider as a side
# effect — and its own comment then named a SIXTH (this controller) as "still
# open". Three consecutive enumerations, each written by someone looking at the
# code, each short by one.
#
# The enumeration is the part that rots, so the enumeration has to be
# executable. That is all this file is.
#
# THE PROPERTY, STATED AS AN EQUALITY. The set of source sites that mint a
# System::Provider, or move an existing row's provider_type, EQUALS the census
# below. Both directions: a new writer appearing is a failure, and a censused
# writer disappearing is a failure too (a stale entry is how a census starts
# lying). An existence check over the writers you already know about cannot see
# the seventh, which is precisely how the fifth and sixth survived.
#
# EVERY ENTRY DECLARES ITS GUARD. Either :registry_sdk_predicate — the site
# asks `Registry.sdk_refusal(type)` before the write and refuses on a non-nil
# answer — or a named exemption. The exemption is not free: the "guarded sites really
# contain the predicate" example below reads the file and checks the tokens are
# actually there, so an entry cannot claim a guard the code does not have. A
# one-line addition to a bare array of paths reads as tidying up and gets
# reviewed as tidying up; an addition that has to name its guard does not.
#
# ══ THIS IS A TRIPWIRE, NOT THE WALL ══════════════════════════════════════
#
# A source scan sees only the spellings it greps for. Invisible to it:
#
#   * a write built at runtime — `Provider.create!(attrs)` where attrs is a
#     hash assembled elsewhere, `send(:update!, h)`, `update_columns(h)`;
#   * raw SQL (`connection.execute("UPDATE system_providers ...")`), psql, or
#     a migration;
#   * a mint reached through a variable holding the class
#     (`klass = ::System::Provider; klass.create!`);
#   * a writer in a Rails root that is not in this checkout at all — the
#     scan globs the roots that ARE here (see .scan_roots: this extension,
#     core server/, worker/, every extensions/*/server and
#     extensions/private/*/server present), so an absent private extension
#     is invisible, and so is anything outside those globs.
#
# The strong form is a model-layer runtime guard inside System::Provider that
# refuses an inoperable provider_type however the write was spelled. This spec
# does not replace it; it blocks the AUTHORED hazard so a runtime guard can be
# designed without new bypasses accumulating underneath it. Read a green run as
# "no new writer was typed in a shape we recognize", not as "the column is
# protected".
#
# CITATION POLICY. References into files this task also edits are by METHOD
# name, never a line number: a line citation added in the commit that shifts
# the lines is wrong on arrival.
#
# A NAMED MODULE, NOT BARE CONSTANTS IN THE EXAMPLE GROUP: a constant assigned
# inside an RSpec.describe block binds to Object, so two lint specs in this
# directory that both name SCAN_GLOBS would silently redefine each other's
# scanner when loaded in the same process.
module ProviderTypeWriterCensus
  SCAN_GLOBS = %w[app/**/*.rb lib/**/*.rb db/seeds/**/*.rb].freeze

  # A mint: a System::Provider (or account.system_providers) row being
  # constructed. `(?![A-Za-z_])` is load-bearing — without it this matches
  # System::ProviderConnection, ProviderRegion, ProviderCredential and every
  # other sibling, none of which carry provider_type.
  # The verb list is longest-first and the tail is `(?!\w)` rather than `\b`:
  # after `find_or_create_by!(` there is no word boundary, so a `\b` tail
  # backtracks the `!` away and the key comes out spelled without it — a
  # census key that never matches the census.
  MINT_RE = /
    (?<recv>(?:::)?System::Provider(?![A-Za-z_])|[\w.@]*system_providers)
    \s*\.\s*
    (?<verb>find_or_create_by|create_or_find_by|first_or_create|create|build|new)
    (?<bang>!?)(?!\w)
  /x

  # A conversion: provider_type moved on a row that already exists.
  INPLACE_RE = /(?<recv>[\w.@]+)\.provider_type\s*=(?!=|~)/
  KWARG_RE   = /(?<verb>update!?|update_columns|update_all|assign_attributes)\s*\(?[^)\n]*provider_type\s*:/
  # Strong params are how a controller reaches the column without ever naming
  # it in an assignment — the shape that made #update the second half of this
  # task's door. Matched over the whole body, not per line, because the list
  # wraps. `[^)]*` does not track nesting: a permit list containing a `)`
  # before :provider_type is invisible here (declared, not fixed — the same
  # bracket honesty as spec/lint/node_module_current_version_write_seam_spec.rb).
  PERMIT_RE  = /permit\((?<args>[^)]*)\)/m

  # `.provider_type =` also fires on Ai::Provider and Git::Provider — unrelated
  # models with a same-named column. Scoping the in-place and permit shapes to
  # files that reference System::Provider (or the association) is the filter;
  # it is declared here rather than buried so a reader knows a same-named
  # column elsewhere is out of scope by design, not by oversight.
  SYSTEM_PROVIDER_RE = /(?:::)?System::Provider(?![A-Za-z_])|system_providers/

  # The predicate tokens a site claiming :registry_sdk_predicate must contain.
  # ONE spelling (IMP-4c825848bb79): the door calls Registry.sdk_refusal and
  # keeps only the door-shaped part of the answer. The leading `\.` is
  # load-bearing — a controller's own `provider_sdk_refusal(` helper must not
  # satisfy the token on its name alone.
  GUARD_TOKENS = [ /Providers::Registry|registry\s*=/, /\.sdk_refusal\(/ ].freeze

  # The clauses the single spelling replaced. Any of these outside the
  # registry and its adapter classes is the predicate being hand-rolled again
  # — the drift the helper exists to prevent. Adapter classes DEFINE
  # `self.sdk_available?` and the registry composes them, so PREDICATE_HOME
  # names those two shapes rather than exempting the whole directory:
  # catalog_sync_service.rb and the local_qemu/pro_cloud/proxmox subtrees sit
  # in app/services/system/providers/ too and are IN scope.
  #
  # NO TRAILING `\b`. `?` is a non-word character, so a `\b` after
  # `sdk_available\?` demands a word character NEXT and therefore matches
  # nothing at all — `sdk_available?(`, `sdk_available?` at end of line and
  # `def self.sdk_available?` all fail it, which would leave a third of this
  # pattern inert while the example below still passed. Same backtracking
  # family as the `(?!\w)` tail on WRITE_RE above. The two word-final
  # alternatives carry an explicit `(?![A-Za-z0-9_])` instead, and the example
  # asserts the pattern still matches every spelling the six doors contained.
  PREDICATE_CLAUSE_RE = /(?<![A-Za-z0-9_])(?:sdk_available\?|sdk_missing_message(?![A-Za-z0-9_])|missing_sdk_gem(?![A-Za-z0-9_]))/
  PREDICATE_HOME       = %r{\Aapp/services/system/providers/(?:registry|[a-z0-9_]*provider)\.rb\z}
  PREDICATE_HOME_LABEL = "app/services/system/providers/{registry.rb,*provider.rb}"

  EXEMPTIONS = %i[
    fixed_type_constant
    fixed_type_literal
  ].freeze

  # path#token => { guard:, why: }. The token is the matched construct with
  # whitespace squeezed — never a line number, so the key survives a shift.
  CENSUS = {
    # ---- request- and agent-reachable writers: all guarded -------------
    "app/controllers/api/v1/system/providers_controller.rb#system_providers.build" => {
      guard: :registry_sdk_predicate,
      why: "REST operator CRUD #create — guarded by #refuse_inoperable_provider_type (IMP-0ddfd8a60032)"
    },
    "app/controllers/api/v1/system/providers_controller.rb#permit:provider_type" => {
      guard: :registry_sdk_predicate,
      why: "REST operator CRUD #update reaches provider_type through strong params — " \
           "guarded by #provider_type_changing? + #refuse_inoperable_provider_type (IMP-0ddfd8a60032)"
    },
    "app/controllers/api/v1/system/provider_credentials_controller.rb#System::Provider.find_or_create_by!" => {
      guard: :registry_sdk_predicate,
      why: "BYOC auto-create-on-first-credential — guarded by #provider_sdk_refusal (35b7ab3e)"
    },
    "app/services/ai/tools/system_fleet_tool.rb#System::Provider.new" => {
      guard: :registry_sdk_predicate,
      why: "MCP system_create_provider — guarded in #create_provider (APO-7, 4c04e50f)"
    },

    # ---- writers that cannot carry a caller-chosen type ----------------
    "app/services/system/account_bootstrap_service.rb#System::Provider.find_or_create_by!" => {
      guard: :fixed_type_constant,
      why: "per-account bootstrap; the type is DEFAULT_PROVIDER_TYPE (pro_cloud), never caller input"
    },
    "app/services/system/account_bootstrap_service.rb#p.provider_type=" => {
      guard: :fixed_type_constant,
      why: "the initializer block of the bootstrap mint above; same constant"
    },
    "db/seeds/node_module_catalog.rb#System::Provider.find_or_create_by!" => {
      guard: :fixed_type_literal,
      why: "seed script, literal local_qemu; not request-reachable"
    },
    "db/seeds/smoke_test_storage_migration_revert_cleanup.rb#System::Provider.find_or_create_by!" => {
      guard: :fixed_type_literal,
      why: "smoke seed, literal local_qemu; not request-reachable"
    },
    "db/seeds/smoke_test_storage_migration_revert_cleanup.rb#p.provider_type=" => {
      guard: :fixed_type_literal,
      why: "the initializer block of the smoke-seed mint above; same literal"
    }
  }.freeze

  def self.extension_root
    Pathname.new(__dir__).join("..", "..").cleanpath
  end

  # @return [Array<Hash>] {key:, path:, line:, source:}
  def self.scan(root = extension_root)
    root = Pathname.new(root)
    SCAN_GLOBS.flat_map { |glob| Dir.glob(root.join(glob).to_s) }.sort.flat_map do |abs|
      rel  = Pathname.new(abs).relative_path_from(root).to_s
      body = File.read(abs)
      system_provider_file = body.match?(SYSTEM_PROVIDER_RE)
      found = []

      body.each_line.with_index do |line, idx|
        # Comments are skipped on purpose: this file, and the guards it
        # polices, quote the forbidden idioms in their own prose.
        next if line.strip.start_with?("#")

        if (m = line.match(MINT_RE))
          receiver = m[:recv].sub(/\A::/, "").sub(/\A.*\./, "")
          found << entry(rel, idx, line, "#{receiver}.#{m[:verb]}#{m[:bang]}", abs: abs)
        end

        next unless system_provider_file

        if (m = line.match(INPLACE_RE))
          found << entry(rel, idx, line, "#{m[:recv]}.provider_type=", abs: abs)
        elsif (m = line.match(KWARG_RE))
          found << entry(rel, idx, line, "#{m[:verb]}(provider_type:)", abs: abs)
        end
      end

      if system_provider_file
        body.to_enum(:scan, PERMIT_RE).each do
          match = Regexp.last_match
          next unless match[:args].match?(/:provider_type\b/)

          idx = body[0...match.begin(0)].count("\n")
          found << entry(rel, idx, "permit(... :provider_type ...)", "permit:provider_type", abs: abs)
        end
      end

      found
    end
  end

  # Every non-comment line outside PREDICATE_HOME that mentions one of the
  # clauses the single spelling replaced. Same roots and globs as the writer
  # scan, so a hand-rolled copy in core or a sibling extension is a finding
  # here exactly as an unlisted writer would be.
  #
  # @return [Array<String>] "<prefix><rel>:<line>: <source>"
  # The files hand_rolled_predicate_sites reads, separated out so the example
  # can assert the set is non-empty and contains a door it knows about: an
  # empty file set and a clean tree are the same green otherwise.
  #
  # @return [Array<Array(String, String, String)>] [key prefix, rel, abs]
  def self.predicate_scan_files
    scan_roots.flat_map do |prefix, root|
      SCAN_GLOBS.flat_map { |glob| Dir.glob(root.join(glob).to_s) }.sort.filter_map do |abs|
        rel = Pathname.new(abs).relative_path_from(root).to_s
        next if rel.match?(PREDICATE_HOME)

        [ prefix, rel, abs ]
      end
    end
  end

  def self.hand_rolled_predicate_sites
    predicate_scan_files.flat_map do |prefix, rel, abs|
      File.read(abs).each_line.with_index.filter_map do |line, idx|
        next if line.strip.start_with?("#")
        next unless line.match?(PREDICATE_CLAUSE_RE)

        "#{prefix}#{rel}:#{idx + 1}: #{line.strip}"
      end
    end
  end

  def self.entry(rel, idx, line, token, abs: nil)
    { key: "#{rel}##{token}", path: rel, abs: abs, line: idx + 1, source: line.strip }
  end

  # extensions/system/server -> extensions/system -> extensions -> <checkout>
  def self.work_root
    extension_root.parent.parent.parent
  end

  # EVERY Rails root in this checkout, each with the prefix its keys carry.
  # One tree cannot support the sentence this file is written to defend
  # ("nothing mints an unguarded System::Provider"): core server/, worker/,
  # the sibling public extensions and any private extension present here are
  # all Rails roots that could hold one, and a scan that reads two of them
  # while the prose says "the public tree" is a coverage claim the code does
  # not make. Roots are discovered by GLOB and never by naming an extension —
  # one extension naming another is exactly what core-purity forbids. Same
  # shape as spec/lint/instance_pool_replenish_gating_spec.rb, for the same
  # reason.
  #
  # This extension keeps the EMPTY prefix, so its census keys stay plain
  # relative paths. Core, worker and the siblings are prefixed; a hit there is
  # a finding in itself (core purity forbids core depending on this extension
  # at all), not merely an unlisted writer.
  #
  # @return [Array<Array(String, Pathname)>] [key prefix, root] pairs
  def self.scan_roots
    labelled = [ [ "", extension_root ],
                 [ "core/", work_root.join("server") ],
                 [ "worker/", work_root.join("worker") ] ]

    (Dir.glob(work_root.join("extensions", "*", "server").to_s) +
     Dir.glob(work_root.join("extensions", "private", "*", "server").to_s)).sort.each do |dir|
      path = Pathname.new(dir)
      slug = path.parent.relative_path_from(work_root.join("extensions")).to_s
      labelled << [ "#{slug}/", path ]
    end

    seen = {}
    labelled.each_with_object([]) do |(prefix, path), acc|
      clean = path.cleanpath
      next unless clean.directory?
      next if seen[clean.to_s]

      seen[clean.to_s] = true
      acc << [ prefix, clean ]
    end
  end

  def self.scan_all
    scan_roots.flat_map do |prefix, root|
      next scan(root) if prefix.empty?

      scan(root).map { |site| site.merge(key: "#{prefix}#{site[:key]}") }
    end
  end
end

RSpec.describe "System::Provider provider_type writer census (IMP-0ddfd8a60032)" do
  let(:sites) { ProviderTypeWriterCensus.scan_all }
  let(:keys)  { sites.map { |s| s[:key] }.uniq.sort }

  # Anti-vacuity. A scanner whose regex stops matching finds nothing and every
  # containment example below passes for the wrong reason.
  it "finds the writers it is supposed to find" do
    expect(sites.size).to be >= ProviderTypeWriterCensus::CENSUS.size
    expect(keys).to include(
      "app/controllers/api/v1/system/providers_controller.rb#system_providers.build",
      "app/services/ai/tools/system_fleet_tool.rb#System::Provider.new"
    )
  end

  it "has no writer that the census does not list" do
    undeclared = keys - ProviderTypeWriterCensus::CENSUS.keys
    expect(undeclared).to be_empty, <<~MSG
      New System::Provider provider_type writer(s) found:

        #{undeclared.join("\n  ")}

      A provider type whose adapter SDK gem is not bundled in this build must
      be refused AT THE WRITE (APO-7). Either apply the predicate

        registry = ::System::Providers::Registry
        if (refusal = registry.sdk_refusal(type))
          # refuse, answering `refusal` in the door's own shape
        end

      and add the site to CENSUS with guard: :registry_sdk_predicate, or add it
      with a named exemption saying why the type cannot be caller-chosen.
    MSG
  end

  it "lists no writer that no longer exists" do
    stale = ProviderTypeWriterCensus::CENSUS.keys - keys
    expect(stale).to be_empty,
      "Censused writer(s) no longer found in the tree — delete the stale entries:\n  #{stale.join("\n  ")}"
  end

  it "declares a real guard or a named exemption for every entry" do
    allowed = [ :registry_sdk_predicate, *ProviderTypeWriterCensus::EXEMPTIONS ]

    ProviderTypeWriterCensus::CENSUS.each do |key, meta|
      expect(allowed).to include(meta[:guard]), "#{key}: unknown guard #{meta[:guard].inspect}"
      expect(meta[:why].to_s).not_to be_empty, "#{key}: no rationale"
    end
  end

  # PRESENCE, not just containment: an entry claiming the predicate must be in
  # a file that actually applies it. Without this the census is a promise the
  # code never has to keep — the exact failure mode of the comment that called
  # itself the platform's only choke point.
  it "guarded sites really contain the SDK predicate" do
    ProviderTypeWriterCensus::CENSUS.each do |key, meta|
      next unless meta[:guard] == :registry_sdk_predicate

      site = sites.find { |candidate| candidate[:key] == key }
      expect(site).not_to be_nil, "#{key}: censused but not found by the scan"

      body = File.read(site[:abs])
      ProviderTypeWriterCensus::GUARD_TOKENS.each do |token|
        expect(body).to match(token), "#{key} claims :registry_sdk_predicate but does not match #{token.inspect}"
      end
    end
  end

  # IMP-4c825848bb79. The predicate used to be spelled six times —
  # `supported? && !sdk_available?` then `sdk_missing_message` — once per
  # door, and each copy could drift on its own. The census's PRESENCE check
  # above then had to recognise every spelling, which is the same rot in a
  # second place. Registry.sdk_refusal is now the one spelling; a door that
  # reaches for the clauses behind it is re-rolling the predicate.
  it "spells the SDK predicate once, in the Registry" do
    # Anti-vacuity, on both ways this scanner can go silently blind: the
    # pattern must still match every spelling the six doors carried before the
    # collapse (a dead alternative reports a clean tree), and the file set it
    # reads must be non-empty and contain a door it knows about.
    [
      "if registry.supported?(type) && !registry.sdk_available?(type)",
      "return error_result(registry.sdk_missing_message(type))",
      "gem = ::System::Providers::Registry.missing_sdk_gem(provider_type)",
      "adapter_class.sdk_available?",
      "def self.sdk_available?"
    ].each do |spelling|
      expect(spelling).to match(ProviderTypeWriterCensus::PREDICATE_CLAUSE_RE),
        "PREDICATE_CLAUSE_RE no longer matches #{spelling.inspect} — the scanner is blind to it"
    end

    [ "registry.sdk_missing_message_for(type)", "no_sdk_available?", "legacy_missing_sdk_gems" ].each do |lookalike|
      expect(lookalike).not_to match(ProviderTypeWriterCensus::PREDICATE_CLAUSE_RE),
        "PREDICATE_CLAUSE_RE now matches the lookalike #{lookalike.inspect}"
    end

    scanned = ProviderTypeWriterCensus.predicate_scan_files
    expect(scanned.map { |(prefix, rel, _abs)| "#{prefix}#{rel}" })
      .to include("app/services/ai/tools/system_fleet_tool.rb")

    hand_rolled = ProviderTypeWriterCensus.hand_rolled_predicate_sites
    expect(hand_rolled).to be_empty, <<~MSG
      The APO-7 SDK predicate is hand-rolled outside #{ProviderTypeWriterCensus::PREDICATE_HOME_LABEL}:

        #{hand_rolled.join("\n  ")}

      Call ::System::Providers::Registry.sdk_refusal(type) instead and refuse
      on a non-nil answer; the door keeps only its own response shape.
    MSG
  end
end
