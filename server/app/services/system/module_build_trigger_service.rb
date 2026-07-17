# frozen_string_literal: true

module System
  # Campaign 019f5885 inc10 — the trigger this campaign's whole dual-run
  # increment exists to feed: turns a "develop just moved from base_sha to
  # head_sha" event (today, a Gitea push webhook — see
  # Api::V1::System::Webhooks::PlatformPushController) into a module-build
  # batch, branching on System::ModuleBuildModeResolver.current:
  #
  #   "gitea"  — full no-op. Returns a Result with dispatched: false,
  #            mode: "gitea", batch: nil. NOTHING native happens — this is
  #            the fail-safe default an operator must explicitly opt out of.
  #
  #   "dual"   — plans the same modules System::ModuleBuildPlannerService
  #            would plan for Gitea, but re-tags each plan entry's oci_ref
  #            with a `native-` prefix (so the shadow build NEVER writes the
  #            `:<sha>` tag the fleet/Gitea build owns), creates the batch
  #            with shadow: true, and dispatches it via
  #            System::NativeModuleBuildOrchestrator — same as any other
  #            batch, just flagged. The batch's own #advance! (already
  #            landed inc9) is what makes shadow: true mean promote: false
  #            at publish time (see NativeModuleBuildOrchestrator#finalize_success!).
  #
  #   "native" — authoritative dispatch: identical to the existing
  #            system_dispatch_module_build_batch MCP path (plain
  #            <short-sha> tags, shadow: false, promotes on publish), just
  #            triggered automatically by the push instead of an operator
  #            call. trigger: "push" either way — see ModuleBuildBatch::TRIGGERS.
  #
  # This is intentionally the ONLY place that knows how to turn a mode into
  # a batch shape — the webhook controller stays a thin auth+parse wrapper,
  # and this service is unit-testable without any HTTP/HMAC machinery.
  class ModuleBuildTriggerService
    Result = Struct.new(:ok?, :mode, :dispatched, :shadow, :batch, :error, keyword_init: true)

    NATIVE_TAG_PREFIX = "native-"

    class << self
      def trigger!(base_sha:, head_sha:, account: nil, force_all: false, source_repo: nil)
        new(account: account).trigger!(base_sha: base_sha, head_sha: head_sha, force_all: force_all, source_repo: source_repo)
      end
    end

    def initialize(account: nil)
      @account = account || resolve_account
    end

    # @param source_repo [String, nil] "<owner>/<repo>" the base_sha..head_sha
    #   diff is taken against (default: the manifest repo — see
    #   System::ModuleBuildPlannerService#ci_build_source_repo). A push of a CORE
    #   change must thread the pushed repo here so the planner diffs the right tree.
    def trigger!(base_sha:, head_sha:, force_all: false, source_repo: nil)
      return failure("no account resolvable") unless @account

      mode = ::System::ModuleBuildModeResolver.current

      case mode
      when ::System::ModuleBuildModeResolver::GITEA
        Result.new(ok?: true, mode: mode, dispatched: false, shadow: false, batch: nil)
      when ::System::ModuleBuildModeResolver::DUAL
        dispatch_batch(mode: mode, base_sha: base_sha, head_sha: head_sha, force_all: force_all, shadow: true, source_repo: source_repo)
      when ::System::ModuleBuildModeResolver::NATIVE
        dispatch_batch(mode: mode, base_sha: base_sha, head_sha: head_sha, force_all: force_all, shadow: false, source_repo: source_repo)
      else
        # ModuleBuildModeResolver.current already folds unknown values to
        # "gitea" — this branch is unreachable in practice, kept as a
        # fail-safe rather than raising out of a webhook-triggered path.
        Result.new(ok?: true, mode: ::System::ModuleBuildModeResolver::GITEA, dispatched: false, shadow: false, batch: nil)
      end
    rescue ::System::ModuleBuildPlannerService::PlanningError => e
      failure(e.message, mode: mode)
    end

    private

    def dispatch_batch(mode:, base_sha:, head_sha:, force_all:, shadow:, source_repo:)
      plan = ::System::ModuleBuildPlannerService.plan(
        base_sha: base_sha, head_sha: head_sha, force_all: force_all, source_repo: source_repo
      )
      plan = shadow ? plan.map { |p| { module: p[:module], oci_ref: "#{NATIVE_TAG_PREFIX}#{p[:oci_ref]}" } } : plan

      batch = ::System::ModuleBuildBatch.create_for(
        account: @account, plan: plan, trigger: "push",
        base_sha: base_sha, head_sha: head_sha, shadow: shadow, source_repo: source_repo
      )

      ::System::NativeModuleBuildOrchestrator.dispatch!(batch: batch)

      Result.new(ok?: true, mode: mode, dispatched: true, shadow: shadow, batch: batch.reload)
    end

    def failure(message, mode: nil)
      Result.new(ok?: false, mode: mode, dispatched: false, shadow: false, error: message)
    end

    # Mirrors System::ModuleBuildPlannerService#resolve_account — the
    # system extension's native-build trigger path is a core-mode,
    # single-tenant concern (multi-tenancy is business-extension-only).
    def resolve_account
      ::Account.find_by(name: "Powernode") || ::Account.first
    end
  end
end
