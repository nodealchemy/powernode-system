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

    # Mirrors scripts/ci-compute-dirty-closure.sh's ALL_TRIGGERS_REGEX
    # default. A change to any of these forces every module to rebuild.
    # (The bash script's env-var override for this regex is intentionally
    # NOT ported — this is a fixed constant here; revisit if a future
    # increment needs the override too.)
    CATCH_ALL_TRIGGER_RX = %r{\A(\.gitea/workflows/build-platform-modules\.yaml|templates/module-repo/Containerfile|scripts/ci-compute-dirty-closure\.sh)\z}.freeze

    # Mirrors the bash script's `^agent/` special case.
    AGENT_PATH_RX = %r{\Aagent/}.freeze
    AGENT_FORCED_MODULE = "powernode-system-base"

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
      # @return [Array<Hash>] [{ module: "<slug>", oci_ref: "<tag>" }, ...]
      #   sorted by module slug. Empty array = nothing to build.
      # @raise [PlanningError] the plan could not be computed (no account,
      #   no Gitea credential, or the Gitea compare API call failed) — a
      #   raised error must NOT be treated as "empty plan" by the caller;
      #   silently planning zero modules on a failed diff would be worse
      #   than surfacing the failure.
      def plan(base_sha:, head_sha:, force_all: false)
        new.plan(base_sha: base_sha, head_sha: head_sha, force_all: force_all)
      end
    end

    def plan(base_sha:, head_sha:, force_all: false)
      account = resolve_account
      raise PlanningError, "no account resolvable" unless account

      dirty = Set.new
      catch_all = force_all

      unless catch_all
        changed_paths_for(account, base_sha, head_sha).each do |path|
          if path.match?(CATCH_ALL_TRIGGER_RX)
            catch_all = true
            next
          end

          if path.match?(AGENT_PATH_RX)
            dirty << AGENT_FORCED_MODULE
            next
          end

          if (m = path.match(MODULE_PATH_RX))
            dirty << m[1]
          end
        end
      end

      known = known_module_names(account)
      dirty = catch_all ? known.dup : (dirty & known)

      closure = expand_reverse_dependencies(account, dirty)
      tag = head_sha.to_s[0, 7]

      closure.sort.map { |slug| { module: slug, oci_ref: tag } }
    end

    private

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

    def known_module_names(account)
      ::System::NodeModule
        .where(account: account)
        .where.not(manifest_yaml: [ nil, "" ])
        .pluck(:name)
        .to_set
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

    # Changed paths for base_sha..head_sha via the Gitea compare API,
    # without a checkout. NOTE: Devops::Git::GiteaApiClient#compare_commits
    # normalizes its `files` field as an unconditional empty array (observed
    # gap, not fixed here — core file, out of scope for this extension-only
    # increment; flagged for a follow-up). Its `commits` ARE populated with
    # real shas, so this walks each commit's own diff via #get_commit_diff
    # (which parses the raw unified-diff text directly and is reliable) and
    # unions the changed filenames across the range.
    def changed_paths_for(account, base_sha, head_sha)
      credential = ::System::CiRunnerRegistrationResolver.new(account: account).credential
      raise PlanningError, "no active Gitea credential resolvable for account #{account.id}" unless credential

      client = ::Devops::Git::ApiClient.for(credential)
      owner, repo = ci_build_source_repo.split("/", 2)

      comparison = client.compare_commits(owner, repo, base_sha, head_sha)
      shas = Array(comparison && comparison[:commits]).filter_map { |c| c[:sha] }.uniq
      return [] if shas.empty?

      shas.flat_map do |sha|
        diff = client.get_commit_diff(owner, repo, sha)
        Array(diff && diff[:files]).filter_map { |f| f[:filename] }
      end.uniq
    rescue ::Devops::Git::ApiClient::ApiError => e
      raise PlanningError, "Gitea compare #{base_sha}..#{head_sha} failed: #{e.class}: #{e.message}"
    end

    def ci_build_source_repo
      ::SiteSetting.get("ci_build_source_repo").presence ||
        ENV["POWERNODE_CI_BUILD_SOURCE_REPO"].presence ||
        CI_BUILD_SOURCE_REPO_DEFAULT
    end
  end
end
