# frozen_string_literal: true

require "tmpdir"
require "fileutils"

module System
  # Campaign 019f5885 inc10 — the structural parity gate inc11's cutover
  # decision hangs on. For every module in a SHADOW System::ModuleBuildBatch
  # (built by System::ModuleBuildTriggerService in "dual" mode), pulls both
  # the Gitea-authoritative `:<sha>` erofs blob and the native `:native-<sha>`
  # blob and structurally diffs them via scripts/module-artifact-diff.sh
  # (inc5) — content-identity, not byte-identity (erofs metadata layout can
  # legitimately differ between build pipelines producing the same rootfs;
  # see that script's header for the full rationale).
  #
  # Emits `system.module_build_parity_ok` on a match and
  # `system.module_build_parity_failed` on any divergence, and records a
  # per-module result on batch.metadata["parity"] (a distinct key from
  # NativeModuleBuildOrchestrator's own metadata["plan"]/metadata["modules"]
  # bookkeeping — this service never touches those).
  #
  # Waivers: a handful of modules (vector, gcsfuse — the live-repo-hook
  # modules flagged in inc5) may LEGITIMATELY differ build-to-build
  # regardless of pipeline, because their build step hooks a live upstream
  # repo rather than a pinned snapshot. The waiver list is a SiteSetting
  # (system.module_builds.parity_waivers, JSON array of module slugs) —
  # never a hardcoded constant — so an operator can grow/shrink it without a
  # deploy as more modules turn out to have the same property.
  #
  # Adapter pattern mirrors System::ModuleOciIngestService /
  # System::ModuleBuildDispatchService: LocalParityAdapter (test/dev —
  # deterministic, per-ref-pair stubbable) and OrasParityAdapter
  # (production — shells out to `oras pull` + module-artifact-diff.sh).
  # Selected by POWERNODE_PARITY_MODE, same env-driven convention as
  # POWERNODE_OCI_MODE / POWERNODE_BUILD_DISPATCH_MODE.
  class ModuleBuildParityService
    Result = Struct.new(:ok?, :error, :results, keyword_init: true)
    ModuleResult = Struct.new(:module, :status, :identical, :gitea_ref, :native_ref,
                              :diff_summary, :error, keyword_init: true)

    class ParityError < StandardError; end

    WAIVERS_SETTING = "system.module_builds.parity_waivers"
    # Seed default — only consulted when the operator hasn't configured the
    # SiteSetting yet. The inc5 live-repo-hook modules.
    DEFAULT_WAIVERS = %w[vector gcsfuse].freeze

    STATUSES = %w[ok failed waived error].freeze

    class << self
      def adapter
        @adapter ||= build_adapter
      end

      def adapter=(replacement)
        @adapter = replacement
      end

      def reset!
        @adapter = nil
      end

      def compare!(batch:)
        new(batch: batch).compare!
      end

      private

      def build_adapter
        mode = ENV.fetch("POWERNODE_PARITY_MODE", default_mode_for_env)
        case mode
        when "oras"  then OrasParityAdapter.new
        when "local" then LocalParityAdapter.new
        else raise ParityError, "Unknown POWERNODE_PARITY_MODE: #{mode.inspect}"
        end
      end

      def default_mode_for_env
        Rails.env.production? ? "oras" : "local"
      end
    end

    def initialize(batch:)
      @batch = batch
      @account = batch.account
    end

    def compare!
      return failure("batch is not a shadow batch") unless @batch.shadow?

      results = module_slugs.map { |slug| compare_module(slug) }
      persist_results!(results)

      Result.new(ok?: true, results: results)
    end

    private

    def module_slugs
      @batch.module_slugs
    end

    def compare_module(slug)
      return waived_result(slug) if waived?(slug)

      node_module = find_node_module(slug)
      return error_result(slug, "NodeModule '#{slug}' not found for account #{@account.id}") unless node_module

      gitea_tag  = @batch.head_sha.to_s[0, 7]
      native_tag = "#{ModuleBuildTriggerService::NATIVE_TAG_PREFIX}#{gitea_tag}"
      gitea_ref  = full_oci_ref(node_module, gitea_tag)
      native_ref = full_oci_ref(node_module, native_tag)

      diff = self.class.adapter.diff(ref_a: gitea_ref, ref_b: native_ref)

      if diff[:error]
        error_result(slug, diff[:error], gitea_ref: gitea_ref, native_ref: native_ref)
      elsif diff[:identical]
        emit_event("system.module_build_parity_ok", severity: :low, module: slug,
                    gitea_ref: gitea_ref, native_ref: native_ref)
        ModuleResult.new(module: slug, status: "ok", identical: true,
                          gitea_ref: gitea_ref, native_ref: native_ref)
      else
        summary = { "added" => diff[:added], "removed" => diff[:removed], "changed" => diff[:changed] }
        emit_event("system.module_build_parity_failed", severity: :high, module: slug,
                    gitea_ref: gitea_ref, native_ref: native_ref, **summary)
        ModuleResult.new(module: slug, status: "failed", identical: false,
                          gitea_ref: gitea_ref, native_ref: native_ref, diff_summary: summary)
      end
    rescue ParityError => e
      # Raised by OrasParityAdapter#ensure_binary! (missing oras/tooling) —
      # gitea_ref/native_ref are already assigned by this point (the raise
      # can only come from inside the adapter.diff call above).
      error_result(slug, e.message, gitea_ref: gitea_ref, native_ref: native_ref)
    end

    def waived_result(slug)
      ModuleResult.new(module: slug, status: "waived")
    end

    def error_result(slug, message, gitea_ref: nil, native_ref: nil)
      Rails.logger.warn("[ModuleBuildParityService] #{slug}: #{message}")
      ModuleResult.new(module: slug, status: "error", error: message, gitea_ref: gitea_ref, native_ref: native_ref)
    end

    def waived?(slug)
      waivers.include?(slug.to_s)
    end

    def waivers
      raw = ::SiteSetting.get(WAIVERS_SETTING)
      configured = Array(raw).map(&:to_s)
      configured.presence || DEFAULT_WAIVERS
    rescue StandardError => e
      Rails.logger.warn("[ModuleBuildParityService] waiver list read failed, using default: #{e.message}")
      DEFAULT_WAIVERS
    end

    def find_node_module(slug)
      @account.system_node_modules.find_by(name: slug)
    end

    # Mirrors NativeModuleBuildOrchestrator#full_oci_ref /
    # ModulePublicationProcessor#build_oci_ref exactly — same
    # registry+namespace+tag shape.
    def full_oci_ref(node_module, tag)
      registry = ::System::DiskImageRegistryConfig.registry_host(account: @account)
      "#{registry}/#{node_module.gitea_repo_full_name}:#{tag}"
    end

    def persist_results!(results)
      serialized = results.each_with_object({}) do |r, memo|
        memo[r.module] = {
          "status"       => r.status,
          "identical"    => r.identical,
          "gitea_ref"    => r.gitea_ref,
          "native_ref"   => r.native_ref,
          "diff_summary" => r.diff_summary,
          "error"        => r.error,
          "compared_at"  => Time.current.iso8601
        }.compact
      end

      @batch.update!(metadata: @batch.metadata.merge("parity" => serialized))
    end

    def failure(message)
      Result.new(ok?: false, error: message, results: [])
    end

    def emit_event(kind, severity:, **payload)
      return unless defined?(::System::Fleet::EventBroadcaster)

      ::System::Fleet::EventBroadcaster.emit!(
        account: @account, kind: kind, severity: severity, source: "module_build_parity_service",
        payload: payload.stringify_keys.merge("batch_id" => @batch.id)
      )
    rescue StandardError => e
      Rails.logger.warn("[ModuleBuildParityService] event emit failed: #{e.message}")
    end

    # ----------------------------------------------------------------------
    # Local adapter — test/dev. Deterministic default (identical) unless a
    # spec stubs a specific ref pair via #stub!, so tests never need a real
    # registry, `oras`, or fsck.erofs on PATH.
    # ----------------------------------------------------------------------
    class LocalParityAdapter
      def initialize
        @overrides = {}
      end

      # Test hook: force a specific diff result (or {error:} failure) for a
      # given (ref_a, ref_b) pair.
      def stub!(ref_a:, ref_b:, result:)
        @overrides[[ ref_a, ref_b ]] = result
      end

      def diff(ref_a:, ref_b:)
        @overrides[[ ref_a, ref_b ]] || { identical: true, added: [], removed: [], changed: [] }
      end
    end

    # ----------------------------------------------------------------------
    # Oras adapter — production. `oras pull` both refs to a scratch dir,
    # locate the .erofs blob each carries, then shell out to
    # scripts/module-artifact-diff.sh (inc5) with --json so the result is
    # machine-parseable. Exit code 1 ("differ") is a normal outcome here,
    # NOT a tooling failure — only exit code 2 (usage/extraction error) or a
    # missing binary is treated as `error:`.
    # ----------------------------------------------------------------------
    class OrasParityAdapter
      # PowernodeSystem::Engine.root is extensions/system/server — the script
      # lives one level up, at extensions/system/scripts/.
      ARTIFACT_DIFF_SCRIPT = File.expand_path("../scripts/module-artifact-diff.sh", ::PowernodeSystem::Engine.root).freeze

      def diff(ref_a:, ref_b:)
        ensure_binary!("oras")
        return { error: "module-artifact-diff.sh not found at #{ARTIFACT_DIFF_SCRIPT}" } unless File.exist?(ARTIFACT_DIFF_SCRIPT)

        Dir.mktmpdir("module-build-parity") do |dir|
          pulled_a = pull(ref_a, File.join(dir, "a"))
          return { error: pulled_a[:error] } if pulled_a[:error]

          pulled_b = pull(ref_b, File.join(dir, "b"))
          return { error: pulled_b[:error] } if pulled_b[:error]

          run_diff(pulled_a[:file], pulled_b[:file], dir)
        end
      end

      private

      def pull(ref, dest_dir)
        FileUtils.mkdir_p(dest_dir)
        _out, err, status = Open3.capture3("oras", "pull", ref, "-o", dest_dir)
        unless status.success?
          return { error: ::System::ShellOutputSanitizer.redact(err.presence) || "oras pull exit #{status.exitstatus} for #{ref}" }
        end

        erofs_file = Dir.glob(File.join(dest_dir, "**", "*.erofs")).first
        return { error: "no .erofs artifact found after `oras pull #{ref}`" } unless erofs_file

        { file: erofs_file }
      end

      def run_diff(image_a, image_b, dir)
        json_out = File.join(dir, "diff.json")
        _out, err, status = Open3.capture3(
          ARTIFACT_DIFF_SCRIPT, image_a, image_b, "--json", json_out, "--quiet"
        )

        # 0 = identical, 1 = differ (both are successful comparisons); only
        # >=2 is a tooling/usage failure.
        if status.exitstatus >= 2
          return { error: ::System::ShellOutputSanitizer.redact(err.presence) || "module-artifact-diff.sh exit #{status.exitstatus}" }
        end

        parsed = JSON.parse(File.read(json_out))
        {
          identical: parsed["identical"] == true,
          added:     Array(parsed["added"]),
          removed:   Array(parsed["removed"]),
          changed:   Array(parsed["changed"])
        }
      rescue JSON::ParserError, Errno::ENOENT => e
        { error: "module-artifact-diff.sh JSON output unreadable: #{e.message}" }
      end

      def ensure_binary!(name)
        _out, _err, status = ::Open3.capture3("which", name)
        return if status.success?

        raise ParityError, "#{name} binary not found on PATH (required for OrasParityAdapter)"
      end
    end
  end
end
