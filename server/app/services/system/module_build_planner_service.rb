# frozen_string_literal: true

module System
  # Server-side Ruby port of scripts/ci-compute-dirty-closure.sh's TRIGGER-PATH
  # logic (campaign 019f5885 inc9 Part A) — computes which modules need
  # rebuilding for a base_sha..head_sha range WITHOUT a git checkout, so the
  # native module-build orchestrator (Part B) can plan a build batch purely
  # from server-side state (a leased builder has no parent-repo checkout to
  # `git diff` against).
  #
  # Ported logic (parity asserted by
  # spec/services/system/module_build_planner_service_spec.rb against the
  # same fixture graph scripts/test-ci-compute-dirty-closure.sh uses):
  #
  #   1. force_all (explicit param OR a catch-all-trigger path found in the
  #      diff) → every module with a manifest.
  #   2. Else: Gitea compare base_sha..head_sha (via Devops::Git::ApiClient)
  #      → changed paths → modules/<slug>/** maps to <slug>; agent/** forces
  #      powernode-system-base; workflow/Containerfile/this-script catch-alls
  #      force step 1.
  #   3. Transitive reverse-dependency expansion via System::ModuleDependency
  #      "requires" edges — the DB's already-resolved capability graph
  #      (populated by ManifestImportService at manifest-import time) stands
  #      in for the bash script's from-scratch per-run manifest parse.
  #
  # DEFERRED to inc12 (explicitly out of scope here, per the campaign plan):
  # apt-closure drift probing (the bash script's step 3). This port covers
  # TRIGGER-PATH only. The bash script remains canonical for the recovery
  # workflow (a from-scratch CI run with a real checkout) — this is an
  # independent implementation for the server-side planning path, not a
  # replacement; the parity spec is what keeps them from drifting apart.
  #
  # Module builds are mutually independent (dependencies are runtime overlay
  # unions, not build inputs) — the returned plan is an unordered SET, not a
  # DAG that needs sequencing.
  class ModuleBuildPlannerService
    class PlanningError < StandardError; end

    # A plan plus the module names the request named (or would have swept in
    # under force_all) that did NOT become builds, each with a reason —
    # imp b9e3e05a5119. #plan keeps returning the bare entries array (every
    # pre-existing caller consumes that shape); callers that want the dropped
    # names call .plan_with_diagnostics instead.
    PlanResult = Struct.new(:entries, :excluded, keyword_init: true)

    # Exclusion reasons (machine-readable; the accompanying :detail is prose).
    #
    #   package_origin — materialized by System::PackageModuleMaterializer from
    #     an upstream apt/rpm package. It has no modules/<slug>/ tree to diff
    #     and no manifest_yaml, so this planner can neither see it dirty nor
    #     build it; it rebuilds through System::PackageClosureBuildBridge's own
    #     `package`-trigger batch (System::NativeModuleBuildOrchestrator skips
    #     the manifest step for that trigger). Correct to exclude — but it was
    #     silent, so force_all reported a clean plan while skipping every
    #     package-origin module in the account.
    #   no_manifest    — a module whose manifest.yaml was never imported.
    #   unknown_module — a modules/<slug>/ path changed but no NodeModule of
    #     that name exists in the account (repo/DB divergence).
    EXCLUDED_PACKAGE_ORIGIN = "package_origin"
    EXCLUDED_NO_MANIFEST    = "no_manifest"
    EXCLUDED_UNKNOWN_MODULE = "unknown_module"

    # How many excluded modules a PlanningError names before summarizing the
    # rest as "+N more". An account whose catalog is all package-origin would
    # otherwise render a multi-KB error string into webhook bodies and logs.
    # Independent of the MCP layer's own payload cap (that one bounds a JSON
    # array, this one bounds a message).
    EXCLUDED_MESSAGE_SAMPLE_LIMIT = 25

    # Mirrors scripts/ci-compute-dirty-closure.sh's ALL_TRIGGERS_REGEX
    # default. A change to any of these forces every module to rebuild.
    # (The bash script's env-var override for this regex is intentionally
    # NOT ported — this is a fixed constant here; revisit if a future
    # increment needs the override too.)
    CATCH_ALL_TRIGGER_RX = %r{\A(\.gitea/workflows/build-platform-modules\.yaml|templates/module-repo/Containerfile|scripts/ci-compute-dirty-closure\.sh)\z}.freeze

    # Mirrors the bash script's `^scripts/module-build/` special case. Those
    # scripts are COPIED into module-forge's rootfs at ITS build time (see
    # modules/module-forge/manifest.yaml), so a builder runs whichever copy was
    # baked into the module-forge erofs it booted. Editing them therefore changes
    # nothing until module-forge is rebuilt — and until this rule existed NOTHING
    # triggered that, so a fix to build-one-module.sh / push.sh / stage*.sh
    # silently never reached any builder. The manifest's "every module-forge
    # rebuild re-syncs those scripts with zero drift risk" holds only if a
    # rebuild is actually triggered.
    BUILD_SCRIPTS_PATH_RX = %r{\Ascripts/module-build/}.freeze
    BUILD_SCRIPTS_FORCED_MODULE = "module-forge"

    # Mirrors the bash script's `^agent/` special case.
    AGENT_PATH_RX = %r{\Aagent/}.freeze
    AGENT_FORCED_MODULE = "powernode-system-base"

    # Paths under agent/ that CANNOT change the artifact system-base ships.
    # Its file_spec is the COMPILED binary (/usr/sbin/powernode-agent,
    # /sbin/powernode-agent) plus /etc/powernode/** and two drop-ins — and the
    # /etc/powernode skeleton comes from the module's own rootfs/ (caught by
    # MODULE_PATH_RX), not from agent source. Verified before narrowing: there is
    # no `go:embed` anywhere in the tree, so no non-Go file can reach the binary,
    # and agent/test/ holds only _test.go.
    #
    # Why this matters more than it looks: system-base is what nearly everything
    # depends on, so reverse-dependency expansion turned ONE edit under agent/
    # into a 22-module batch (measured on the live planner, 2026-08-11). 142 of
    # the tree's 209 Go files are _test.go and none of them are in the binary.
    #
    # Excluded paths are NOT dropped — they fall through to the manifest-repo
    # rules below and plan powernode-extension-system, which genuinely does ship
    # agent sources as files (only agent/dist is masked out of that layer). So a
    # test-only edit rebuilds one module instead of the catalog.
    #
    # A comment-only change inside a real .go file still triggers: a path rule
    # cannot see that the compiled output is unchanged. Over-triggering there is
    # the safe direction.
    AGENT_UNSHIPPED_PATH_RX = %r{
      \Aagent/(?:
        .*_test\.go\z      |
        test/              |
        testdata/          |
        docs/              |
        \.[^/]+/           |
        [^/]*\.md\z
      )
    }x.freeze

    # Mirrors MODULES_DIR default ("modules") + the bash script's
    # `^${MODULES_DIR}/([^/]+)/` capture.
    MODULE_PATH_RX = %r{\Amodules/([^/]+)/}.freeze

    # Same SiteSetting -> ENV -> default chain as
    # Api::V1::System::NodeApi::ConfigController#ci_build_source_repo (that
    # copy is a private controller method, not reusable directly) — the repo
    # whose modules/<slug> tree this planner diffs. Duplicated intentionally;
    # flagged as a follow-up consolidation candidate (shared config seam),
    # not fixed here — out of scope for inc9 Part A.
    CI_BUILD_SOURCE_REPO_DEFAULT = "powernode/powernode-system"

    # The CORE repo. Its tree has no modules/<slug>/ at all, so the manifest-repo
    # rules above match NOTHING in it — a core-only change (server/**) planned
    # zero modules and returned SILENTLY, because guard_against_empty_plan! only
    # fires once at least one candidate was named. Passing source_repo was
    # necessary but never sufficient; there was no rule to match.
    CORE_SOURCE_REPO_DEFAULT = "powernode/powernode-platform"

    # Paths that ship in NO module, in EITHER repo: prose, CI config, repo
    # hygiene. Shared deliberately — a file that is an inert no-op in one repo
    # and a rebuild trigger in the other is exactly the asymmetry that hides a
    # stale deploy. A range touching only these stays a quiet no-op, otherwise
    # every docs/reference/auto regeneration becomes a failed dispatch.
    UNSHIPPED_COMMON_RX = %r{
      \A(?:
        docs/                                      |
        \.(?:git|github|gitea|ci|claude|gitflow)/   |
        \.[^/]+\z                                  |
        [^/]*\.md\z                                |
        (?:LICENSE|VERSION)\z
      )
    }x.freeze

    # Core: everything else unmapped is a MISSING RULE and fails loudly (see
    # #guard_against_unmapped_core_change!), so the safe direction for anything
    # ambiguous is to leave it OUT.
    CORE_UNSHIPPED_PATH_RX = UNSHIPPED_COMMON_RX

    # How many unmapped core paths a PlanningError names before summarizing the
    # rest, for the same reason as EXCLUDED_MESSAGE_SAMPLE_LIMIT above.
    UNMAPPED_CORE_SAMPLE_LIMIT = 20

    # The manifest repo IS the system extension's tree, and
    # powernode-extension-system's file_spec is /opt/powernode/extensions/system/**
    # — so a push here changes what that module ships unless the path is masked
    # out of it. On top of the inert set above, that manifest also masks
    # initramfs/ and tmp/ (it masks modules/ and agent/dist/ too, but those match
    # their own rules first and never reach this test).
    #
    # Tracking the manifest's mask is the point: inventing extra exclusions here
    # is how a shipped file silently stops triggering a rebuild, which is the bug
    # this closes. Prose stays exempt because nothing on a node reads it.
    MANIFEST_UNSHIPPED_PATH_RX = Regexp.union(UNSHIPPED_COMMON_RX, %r{\A(?:initramfs/|tmp/)}).freeze
    MANIFEST_EXTENSION_MODULE = "powernode-extension-system"

    # Core path -> the module that PACKAGES that tree. Applied ONLY when the diff
    # is taken against the core repo: `server/` exists in BOTH repos and means
    # different things (core's Rails app vs the extension's), so applying these
    # unconditionally would mis-plan every manifest-repo diff.
    #
    # extensions/system is a submodule in core, so a pointer bump appears as the
    # bare gitlink path with no trailing slash — hence the (/|\z).
    CORE_PATH_MODULES = {
      %r{\Aserver/}                  => "powernode-hub-backend",
      # hub-backend's file_spec is /opt/powernode/{server/**,scripts/**,
      # extensions_loader_helper.rb} — all three ship in the layer, so a change
      # to any of them must rebuild it. Omitting the latter two left exactly the
      # silent zero-plan this map exists to close.
      %r{\Ascripts/}                 => "powernode-hub-backend",
      %r{\Aextensions_loader_helper\.rb\z} => "powernode-hub-backend",
      %r{\Aworker/}                  => "powernode-hub-worker",
      %r{\Afrontend/}                => "powernode-hub-frontend",
      %r{\Aextensions/system(/|\z)}  => "powernode-extension-system"
    }.freeze

    class << self
      # @param base_sha [String] the pre-push commit (diff base)
      # @param head_sha [String] the post-push commit (diff head) — also the
      #   source of the planned oci_ref/tag (its first 7 chars, mirroring
      #   scripts/module-build/push.sh's `git rev-parse --short HEAD`
      #   fallback tag convention — the exact TAG semantics
      #   module-forge-build.sh's OCI_REF env var expects, NOT a full OCI
      #   reference despite the key name).
      # @param force_all [Boolean] skip the diff entirely and plan every
      #   module with a manifest (manual full-rebuild / CVE sweep).
      # @param source_repo [String, nil] "<owner>/<repo>" whose modules/<slug>
      #   tree the base_sha..head_sha diff is taken against. nil → the default
      #   manifest repo (#ci_build_source_repo). A build dispatched for a CORE
      #   (powernode-platform) change MUST pass the core repo here — diffing the
      #   default manifest repo for a core sha range silently plans 0 modules.
      # @return [Array<Hash>] [{ module: "<slug>", oci_ref: "<tag>" }, ...]
      #   sorted by module slug. Empty array = nothing to build.
      # @raise [PlanningError] the plan could not be computed (no account,
      #   no Gitea credential, the Gitea compare API call failed, a real
      #   commit range yielded zero changed files, or the request named
      #   modules but resolved to none) — a raised error must NOT be
      #   treated as "empty plan" by the caller; silently planning zero modules
      #   on a failed diff would be worse than surfacing the failure.
      def plan(base_sha:, head_sha:, force_all: false, source_repo: nil)
        plan_with_diagnostics(base_sha: base_sha, head_sha: head_sha, force_all: force_all, source_repo: source_repo).entries
      end

      # As #plan, but returns a PlanResult carrying both the entries and the
      # module names that were dropped, with a reason each (imp b9e3e05a5119).
      # @return [PlanResult]
      def plan_with_diagnostics(base_sha:, head_sha:, force_all: false, source_repo: nil)
        new.plan_with_diagnostics(base_sha: base_sha, head_sha: head_sha, force_all: force_all, source_repo: source_repo)
      end
    end

    def plan(base_sha:, head_sha:, force_all: false, source_repo: nil)
      plan_with_diagnostics(base_sha: base_sha, head_sha: head_sha, force_all: force_all, source_repo: source_repo).entries
    end

    def plan_with_diagnostics(base_sha:, head_sha:, force_all: false, source_repo: nil)
      account = resolve_account
      raise PlanningError, "no account resolvable" unless account

      dirty = Set.new
      catch_all = force_all
      changed_file_count = 0
      repo_full_name = nil
      unmapped_core = []

      unless catch_all
        repo_full_name = source_repo.presence || ci_build_source_repo
        core_repo = core_source_repo?(repo_full_name)
        changed_paths = changed_paths_for(account, base_sha, head_sha, repo_full_name)
        changed_file_count = changed_paths.size

        changed_paths.each do |path|
          if path.match?(CATCH_ALL_TRIGGER_RX)
            catch_all = true
            next
          end

          if core_repo
            # Core tree: map the packaging module. Neither modules/ nor agent/
            # exists in the core repo, so those rules are skipped entirely.
            if (slug = CORE_PATH_MODULES.find { |rx, _| path.match?(rx) }&.last)
              dirty << slug
            elsif !path.match?(CORE_UNSHIPPED_PATH_RX)
              # Ships somewhere, but no rule says where — remembered so an
              # otherwise-empty plan can name it instead of returning success.
              unmapped_core << path
            end
            next
          end

          if path.match?(BUILD_SCRIPTS_PATH_RX)
            dirty << BUILD_SCRIPTS_FORCED_MODULE
            next
          end

          # agent/ keeps its single system-base target when the change can reach
          # the compiled binary. The agent SOURCE also rides along in the
          # extension layer, but nothing executes it from there, so a shipping
          # change plans system-base ALONE rather than both.
          #
          # A change that cannot reach the binary (tests, docs, CI config) falls
          # THROUGH deliberately: it still alters what the extension layer ships,
          # so the rules below plan that one module instead of forcing a
          # system-base rebuild and its whole dependency closure.
          if path.match?(AGENT_PATH_RX) && !path.match?(AGENT_UNSHIPPED_PATH_RX)
            dirty << AGENT_FORCED_MODULE
            next
          end

          if (m = path.match(MODULE_PATH_RX))
            dirty << m[1]
            next
          end

          dirty << MANIFEST_EXTENSION_MODULE unless path.match?(MANIFEST_UNSHIPPED_PATH_RX)
        end
      end

      known = known_module_names(account)

      # Every name this request put on the table: under a catch-all that is
      # the account's whole module catalog (manifest or not), otherwise the
      # slugs the diff itself named. Whatever `known` then drops out of it is
      # what the caller never hears about unless we say so.
      candidates = catch_all ? all_module_names(account) : dirty.dup
      dirty = catch_all ? known.dup : (dirty & known)

      closure = expand_reverse_dependencies(account, dirty)
      excluded = excluded_entries(account, candidates - known)

      guard_against_unmapped_core_change!(
        closure: closure, catch_all: catch_all,
        unmapped: unmapped_core, repo_full_name: repo_full_name
      )

      guard_against_empty_plan!(
        closure: closure, catch_all: catch_all, candidates: candidates,
        known: known, excluded: excluded, changed_file_count: changed_file_count
      )

      tag = head_sha.to_s[0, 7]

      PlanResult.new(
        entries: closure.sort.map { |slug| { module: slug, oci_ref: tag } },
        excluded: excluded
      )
    end

    private

    # THE SILENT-ZERO GUARD. #guard_against_empty_plan! below only fires once at
    # least one candidate was NAMED, so a core diff whose paths matched no rule
    # slipped past it and reported a successful build of nothing — the shape that
    # hid three stacked defects behind a single "success" (two live dispatches
    # planned 0 modules before it was found). The two guards in
    # #changed_paths_for already cover an empty diff and a failed compare, so
    # this closes the last silent path: a compare that returns files none of
    # which map anywhere.
    #
    # Scoped to the CORE repo deliberately. There, an unmapped path is a missing
    # rule — core ships in modules unless it is docs/CI hygiene. The manifest
    # repo has legitimate zero-plan pushes and is left exactly as it was.
    def guard_against_unmapped_core_change!(closure:, catch_all:, unmapped:, repo_full_name:)
      return if catch_all || !closure.empty? || unmapped.empty?

      shown = unmapped.first(UNMAPPED_CORE_SAMPLE_LIMIT)
      more  = unmapped.size - shown.size
      raise PlanningError,
            "planned 0 modules from #{repo_full_name}: no core path rule covers " \
            "#{shown.join(', ')}#{more.positive? ? " (+#{more} more)" : ''} — refusing to report a " \
            "successful build that would build nothing. Either add a CORE_PATH_MODULES rule for the " \
            "module that packages these files, or if they ship in no module add them to " \
            "CORE_UNSHIPPED_PATH_RX. If you meant to diff the manifest repo instead, pass source_repo."
    end

    # A request that NAMED modules (or asked for all of them) and resolved to
    # zero builds is the "shipped a successful build that built nothing"
    # signature — and nothing downstream can catch it: a 0-module batch runs
    # System::NativeModuleBuildOrchestrator#finish_empty_batch!, which walks
    # AASM straight through to `complete`. Fail here, the last layer that
    # still knows what was asked for.
    #
    # NOT a failure: a non-empty diff that touched no module trigger path at
    # all (docs/, README) — nothing named a module, so nothing was expected to
    # build. That stays a legitimate no-op, as does an empty commit range.
    def guard_against_empty_plan!(closure:, catch_all:, candidates:, known:, excluded:, changed_file_count:)
      return unless closure.empty?
      return unless catch_all || candidates.any?

      raise PlanningError, "#{empty_plan_summary(catch_all, candidates, known, changed_file_count)} " \
                           "(#{format_excluded(excluded)}) — refusing to report a successful build that " \
                           "would build nothing.#{retirement_hint(excluded)}"
    end

    def core_source_repo?(repo_full_name)
      repo_full_name.to_s.strip.casecmp?(core_source_repo)
    end

    def core_source_repo
      ::SiteSetting.get("ci_core_source_repo").presence ||
        ENV["CI_CORE_SOURCE_REPO"].presence ||
        CORE_SOURCE_REPO_DEFAULT
    rescue StandardError
      CORE_SOURCE_REPO_DEFAULT
    end

    # A pure module-deletion push (the modules/<slug>/ tree goes away in the
    # same push that retires the module) lands here: the slug is dirty, no
    # NodeModule of that name is left, so the plan is empty and this guard
    # fires. That is correct — the push genuinely has nothing to build — but
    # the bare error reads like a defect, so say which case the reader is in.
    # There is no ordering that avoids it: delete the row first and the slug
    # is unknown (this path); delete the tree first and the still-registered
    # module is planned, then fails in the builder with no source to check
    # out. The push simply has no build to do.
    def retirement_hint(excluded)
      return "" unless excluded.any? { |e| e[:reason] == EXCLUDED_UNKNOWN_MODULE }

      " If one of these was deliberately retired (its NodeModule deleted via system_delete_module), a push " \
        "that only removes its modules/<slug>/ tree has nothing left to build and this failure is expected — " \
        "no re-dispatch needed."
    end

    def empty_plan_summary(catch_all, candidates, known, changed_file_count)
      if catch_all
        # "0 of 0 have manifests" reads as a bug; an empty catalog is a
        # diagnosis, so say that instead.
        return "force_all/catch-all planned 0 modules — no modules exist in this account, so there is " \
               "nothing to build" if candidates.empty?

        "force_all/catch-all planned 0 modules — #{known.size} of #{candidates.size} module(s) in this " \
          "account have an imported manifest_yaml"
      else
        "planned 0 modules for a non-empty change set — #{changed_file_count} changed file(s) named module " \
          "path(s) [#{candidates.to_a.sort.join(', ')}], none of which intersects the #{known.size} " \
          "buildable module(s) in this account"
      end
    end

    def format_excluded(excluded)
      return "no excluded modules" if excluded.empty?

      shown = excluded.first(EXCLUDED_MESSAGE_SAMPLE_LIMIT).map { |e| "#{e[:module]} (#{e[:reason]})" }.join(", ")
      overflow = excluded.size - EXCLUDED_MESSAGE_SAMPLE_LIMIT

      overflow.positive? ? "#{shown}, +#{overflow} more" : shown
    end

    # Why each candidate name did not become a build. Package-origin modules
    # are the common, CORRECT case (see EXCLUDED_PACKAGE_ORIGIN) — the point
    # is that the caller is told, not that the exclusion is wrong.
    def excluded_entries(account, names)
      return [] if names.empty?

      rows = ::System::NodeModule
               .where(account: account, name: names.to_a)
               .includes(:package_module_link)
               .index_by(&:name)

      names.to_a.sort.map do |name|
        mod = rows[name]

        if mod.nil?
          excluded_entry(name, EXCLUDED_UNKNOWN_MODULE,
                         "no NodeModule named \"#{name}\" in this account — modules/#{name}/ changed in the " \
                         "diff but no module of that name is registered; either import its manifest (a new " \
                         "module) or, if it was deliberately retired via system_delete_module, this push has " \
                         "nothing left to build for it and the exclusion is expected")
        elsif mod.package_sourced?
          # package_module_link_id: system_refresh_package_module (the remedy)
          # keys off the LINK, not the module — carry it so acting on this
          # exclusion doesn't need a second lookup.
          excluded_entry(name, EXCLUDED_PACKAGE_ORIGIN,
                         "package-origin module (materialized from an upstream package, so it has neither a " \
                         "modules/#{name}/ tree to diff nor a manifest_yaml) — it rebuilds through the " \
                         "package-closure trigger, not this planner; use system_refresh_package_module")
            .merge(package_module_link_id: mod.package_module_link.id)
        else
          excluded_entry(name, EXCLUDED_NO_MANIFEST,
                         "no manifest_yaml imported — the planner only builds modules whose manifest has been " \
                         "imported (System::ManifestImportService)")
        end
      end
    end

    def excluded_entry(name, reason, detail)
      { module: name, reason: reason, detail: detail }
    end

    # Single-account resolution — the system extension's native-build CI
    # planning is a core-mode, single-tenant concern (multi-tenancy is
    # business-extension-only per platform convention). Mirrors
    # System::PhysicalEnrollmentService's existing "the account" fallback.
    # NOTE for Part B: the given interface signature has no account: kwarg;
    # if the orchestrator has its own account source of truth, flag this as
    # a deviation and pass it through explicitly instead.
    def resolve_account
      ::Account.find_by(name: "Powernode") || ::Account.first
    end

    # The buildable set: a module this planner can build has a manifest.yaml
    # imported (its build inputs live under modules/<slug>/). Anything else is
    # reported via #excluded_entries rather than silently dropped.
    def known_module_names(account)
      ::System::NodeModule
        .where(account: account)
        .where.not(manifest_yaml: [ nil, "" ])
        .pluck(:name)
        .to_set
    end

    def all_module_names(account)
      ::System::NodeModule.where(account: account).pluck(:name).to_set
    end

    # BFS over System::ModuleDependency "requires" edges (dependency_id =
    # provider, node_module_id = dependent) — the DB's already-resolved
    # reverse-dependency graph. Mirrors the bash script's
    # DEPENDENTS[provider] += dependent expansion (step 4).
    def expand_reverse_dependencies(account, dirty_names)
      return Set.new if dirty_names.empty?

      seed_ids = ::System::NodeModule.where(account: account, name: dirty_names.to_a).pluck(:id)
      closure_ids = Set.new(seed_ids)
      queue = seed_ids.dup

      until queue.empty?
        current_id = queue.shift
        ::System::ModuleDependency.requires.where(dependency_id: current_id).pluck(:node_module_id).each do |dep_id|
          next if closure_ids.include?(dep_id)

          closure_ids << dep_id
          queue << dep_id
        end
      end

      ::System::NodeModule.where(id: closure_ids.to_a).pluck(:name).to_set
    end

    # Changed paths for base_sha..head_sha, without a checkout. Empirically
    # (live probe, 2026-07-17) today's Gitea compare API returns ONLY
    # {commits,total_commits} — no top-level `files` array — and the raw `.diff`
    # endpoint that Devops::Git::GiteaApiClient#get_commit_diff walks 404s, so
    # neither yields changed files. The reliable source is each commit's own
    # /git/commits/<sha> detail, whose `files[]` array #get_commit surfaces. So:
    # compare to enumerate the range's commit shas, then union each commit's own
    # changed filenames. `source_repo` overrides the default manifest repo
    # (#ci_build_source_repo) so a build dispatched for a CORE (powernode-platform)
    # change diffs the repo the change actually lives in — diffing the wrong repo
    # silently planned 0 modules.
    # Takes the ALREADY-RESOLVED repo name — the caller resolves it so the path
    # rules can branch on which repo is being diffed.
    def changed_paths_for(account, base_sha, head_sha, repo_full_name)
      credential = ::System::CiRunnerRegistrationResolver.new(account: account).credential
      raise PlanningError, "no active Gitea credential resolvable for account #{account.id}" unless credential

      client = ::Devops::Git::ApiClient.for(credential)
      owner, repo = repo_full_name.split("/", 2)

      comparison = client.compare_commits(owner, repo, base_sha, head_sha)
      commits = Array(comparison && comparison[:commits])
      return [] if commits.empty? # base == head / nothing pushed — a legit no-op

      # Forward-compat fast path: if a future Gitea populates the compare's own
      # affected-files list (#compare_commits maps it when present), use it and
      # skip the per-commit round-trips. Empty on today's Gitea.
      files = Array(comparison[:files]).filter_map { |f| f[:filename] }.uniq

      if files.empty?
        # Today's reality: union each commit's own /git/commits/<sha> files[]
        # (#get_commit). A failed detail fetch RAISES (ApiError) — caught below
        # and surfaced as a hard PlanningError, never a silent empty change.
        files = commits.filter_map { |c| c[:sha] }.flat_map do |sha|
          detail = client.get_commit(owner, repo, sha)
          Array(detail && detail[:files]).filter_map { |f| f[:filename] }
        end.uniq
      end

      # HARD-FAIL guard (imp 019f71e2 / 019f71e3): a real commit range that yields
      # ZERO changed files across BOTH the compare list and the per-commit walk is
      # the silent-diff-failure signature — refuse to plan an empty build off it
      # (building nothing while reporting success is the bug this guard prevents).
      if files.empty?
        raise PlanningError,
              "Gitea compare of #{repo_full_name} #{base_sha.to_s[0, 7]}..#{head_sha.to_s[0, 7]} returned " \
              "#{commits.size} commit(s) but zero changed files — refusing to plan an empty build " \
              "(a requested change that maps to 0 modules is a failure, not a no-op)"
      end

      files
    rescue ::Devops::Git::ApiClient::ApiError => e
      raise PlanningError,
            "Gitea compare of #{repo_full_name} #{base_sha}..#{head_sha} failed: #{e.class}: #{e.message} " \
            "— if these shas live in a different repo, pass source_repo (core changes need " \
            "source_repo: #{CORE_SOURCE_REPO_DEFAULT})"
    end

    def ci_build_source_repo
      ::SiteSetting.get("ci_build_source_repo").presence ||
        ENV["POWERNODE_CI_BUILD_SOURCE_REPO"].presence ||
        CI_BUILD_SOURCE_REPO_DEFAULT
    end
  end
end
