# frozen_string_literal: true

module System
  # Runs the post-version-creation chain for a module publication:
  # manifest re-import → OCI ingest → skill registration → fleet event
  # emission. Extracted from GiteaModuleController so the same chain
  # can run from two callers:
  #
  #   - The synchronous webhook receiver (when worker dispatch is
  #     unavailable / disabled / in dev — same behavior as before)
  #   - The internal processing endpoint hit by the async worker job
  #     (production path — webhook returns 200 immediately)
  #
  # Each side effect is independently non-fatal: manifest fetch
  # failure, OCI ingest failure, skill registrar raise, broadcaster
  # raise — none of these abort the chain. Failure surfaces via
  # log + a system.module_publish_failed FleetEvent so the operator
  # sees the issue in the dashboard rather than silent loss.
  #
  # Reference: Golden Eclipse plan M1 (module supply chain) — async
  # variant from the audit notes 2026-05-02.
  class ModulePublicationProcessor
    Result = Struct.new(:ok?, :error, :node_module_version, :artifacts,
                        :resolved_dependencies, keyword_init: true)

    class << self
      def process!(node_module:, tag:, promote: true, native_build: nil)
        new.process!(node_module: node_module, tag: tag, promote: promote, native_build: native_build)
      end
    end

    # @param promote [Boolean] whether a successful ingest advances
    #   node_module.current_version_id (campaign 019f5885 inc10 — dual-run
    #   shadow mode). Default true preserves every existing caller's
    #   behavior (Gitea webhook, CI-direct publish, the native authoritative
    #   path). Callers publishing a SHADOW native build (mode == "dual")
    #   pass promote: false so the ingest still creates a NodeModuleVersion +
    #   ModuleArtifact rows (parity comparison needs those) without ever
    #   moving current_version_id off whatever the Gitea build published —
    #   the fleet keeps consuming exactly what it consumed before.
    # @param native_build [Hash, nil] present ONLY for native (module-forge)
    #   builds — carries the agent build result's {fsverity_root:,
    #   architecture:}. When present, the artifact is recorded from the
    #   registry-resolved erofs LAYER (blob) digest via
    #   ModuleOciIngestService.ingest_native! instead of the multi-arch
    #   index + cosign ingest! path. nil (every Gitea webhook / CI-direct
    #   caller) preserves the exact prior behavior — ingest! is called
    #   byte-for-byte as before. See NativeModuleBuildOrchestrator#finalize_success!.
    def process!(node_module:, tag:, promote: true, native_build: nil)
      return failure("node_module required") unless node_module
      return failure("tag required") if tag.blank?

      # Order matters: refresh manifest FIRST so the version snapshot
      # captures the imported declaration, not stale module state.
      resolved_deps = refresh_manifest!(node_module, tag)
      node_module_version = find_or_create_version(node_module, tag)

      # Single-format ingest — every CI publish produces one erofs OCI
      # ref. Cosign verification + per-arch ModuleArtifact rows happen
      # inside ModuleOciIngestService; this processor records the
      # canonical metadata into NodeModuleVersion.artifacts JSONB.
      oci_ref = build_oci_ref(node_module, tag)
      result = ingest_artifact(node_module, node_module_version, oci_ref, native_build)

      if result.ok?
        canonical = result.module_artifacts.find { |a| a.architecture == "amd64" } ||
                    result.module_artifacts.first
        if canonical
          node_module_version.update_columns(
            artifacts: {
              ::System::NodeModuleVersion::PRIMARY_ARTIFACT_FORMAT => {
                "oci_ref"       => oci_ref,
                "oci_digest"    => canonical.oci_digest,
                "fsverity_root" => canonical.fsverity_root_hash,
                "size"          => canonical.size_bytes,
                "media_type"    => canonical.media_type
              }
            }
          )
          # The blob signature the on-node agent can verify — produced HERE,
          # after the ingest above verified the builder's image signature, so
          # the bundle attests "the platform verified and re-signed exactly
          # these bytes". Non-blocking: a failure is logged + emitted and the
          # publish continues unsigned (see ModuleBlobSigner). Before the
          # promotion decision so the opt-in signature gate below sees it.
          ::System::ModuleBlobSigner.attach!(node_module_version, node_module: node_module)
        end
        # An artifact that contains nothing must never become current_version.
        # Publishing it is fine — the row is kept so a bad build can be
        # inspected — but promotion is the step that reaches the fleet, and on
        # 2026-08-07 promoting two zero-file erofs blobs made agents hot-prune
        # /usr/local/go and /usr/local/bin/gitleaks off a live node's root.
        # promoted is the OUTCOME, not the request. Passing the `promote`
        # parameter to the event meant a withheld promotion still published
        # system.module_published with promoted: true, so anything reading the
        # fleet event stream (or a UI reading payload.promoted) believed the bad
        # version was current while current_version_id still pointed at the
        # previous one. The REST controller already reports the real outcome
        # (promoted_to_current: current_version_id == version.id).
        # IMP-26b7f0004a49 phase 1 — pure (the annotations are already in hand
        # from the ingest above; no network, no DB), so computing it up front
        # rather than mid-`elsif` costs nothing and keeps the chain readable.
        core_verdict = core_provenance_verdict(node_module, result, native_build)

        promoted = false
        if promote
          if !auto_promote?(node_module)
            hold_promotion_by_policy!(node_module, node_module_version, tag)
          elsif !promotable_artifact?(canonical)
            withhold_promotion!(node_module, node_module_version, canonical, tag)
          elsif core_verdict.refused?
            # Checked AFTER the non-empty floor: an artifact that fails both
            # should report the emptier, more fundamental problem.
            withhold_promotion_for_core_drift!(node_module, node_module_version, tag, core_verdict)
          elsif (unsigned_reason = ::System::Fleet::PromotionCriteria.signature_gate(node_module_version.reload))
            # Opt-in (module_promotion_require_signature; DEFAULT OFF). Publish
            # auto-promotes straight to the fleet, so a promote gate that lived
            # only on the staging->blessed ladder would be inert here.
            withhold_promotion_unsigned!(node_module, node_module_version, tag, unsigned_reason)
          else
            promote_current_version(node_module, node_module_version)
            # Read the STATE, not promote_to_version!'s return: that returns
            # false for an already-current version, which is a successful no-op
            # (a republished tag), not a withheld promotion. update_columns
            # refreshes the in-memory attribute, so no reload is needed.
            promoted = node_module.current_version_id == node_module_version.id
          end
        end
        # restart_after_update: promotion ARMS the version (inside
        # NodeModule#promote_to_version!, the sanctioned writer and arm!'s only
        # call site — so both rollback routes arm too: the MCP verb calls it
        # directly and ModuleVersionService#rollback_to, behind the REST route,
        # promotes through it since IMP-b7abf6c777da; the census of writers that
        # still bypass it is spec/lint/node_module_current_version_write_seam_spec.rb),
        # and deliberately does NOT enqueue anything here.
        # At this point no instance has materialized the new artifact yet, so
        # enqueueing a restart would restart into the OLD files — the same
        # ordering bug behind the two outages of 2026-08-16. The restart is
        # gated on each instance's own reported digest, at heartbeat time.
        # See System::RestartAfterUpdate.
        register_skills_for(node_module)
        emit_published_event(node_module, node_module_version, oci_ref, result.module_artifacts, tag, promoted)
        Result.new(
          ok?: true,
          node_module_version: node_module_version,
          artifacts: result.module_artifacts,
          resolved_dependencies: resolved_deps
        )
      else
        Rails.logger.warn "[ModulePublicationProcessor] ingest failed: #{result.error}"
        emit_publish_failed_event(node_module, tag, result.error)
        Result.new(
          ok?: false,
          error: result.error,
          node_module_version: node_module_version,
          resolved_dependencies: resolved_deps
        )
      end
    end

    private

    def failure(message)
      Result.new(ok?: false, error: message, resolved_dependencies: [])
    end

    # Routes to the correct OCI ingest path. native_build present (module-forge
    # single-arch push) → resolve the real erofs blob digest from the registry;
    # nil (Gitea webhook / CI-direct publish) → the unchanged multi-arch index +
    # cosign ingest! path.
    def ingest_artifact(node_module, node_module_version, oci_ref, native_build)
      return ingest_default(node_module_version, oci_ref) unless native_build

      ::System::ModuleOciIngestService.ingest_native!(
        node_module_version: node_module_version,
        oci_ref: oci_ref,
        account: node_module.account,
        fsverity_root: native_build[:fsverity_root] || native_build["fsverity_root"],
        architecture: native_build[:architecture] || native_build["architecture"]
      )
    end

    def ingest_default(node_module_version, oci_ref)
      ::System::ModuleOciIngestService.ingest!(
        node_module_version: node_module_version,
        oci_ref: oci_ref
      )
    end

    # Registry host resolves through the same platform config DK1/DK4 built
    # for disk images (AdminSetting -> SecretStore/ENV -> Gitea provider
    # credential) — it's the same Gitea-hosted OCI registry, just a
    # different repo path. ENV.fetch stays as a final, dev-only fallback for
    # a box with neither AdminSetting nor a Gitea credential configured.
    def build_oci_ref(node_module, tag)
      registry = ::System::DiskImageRegistryConfig.registry_host(account: node_module.account).presence ||
                 ENV.fetch("POWERNODE_OCI_REGISTRY", ::System::DiskImageRegistryConfig::PLACEHOLDER_HOST)
      # gitea_repo_full_name is blank for every platform module (only the 5
      # custom per-repo modules set it). Mirror push.sh's hardcoded
      # `powernode/<module>` namespace as the fallback so the ingested/signed
      # ref matches where the artifact was actually pushed — otherwise this
      # builds `<registry>/:<tag>` (empty repo) and oras/cosign reject it.
      repo = node_module.gitea_repo_full_name.presence || "powernode/#{node_module.name}"
      "#{registry}/#{repo}:#{tag}"
    end

    # Idempotent: if a NodeModuleVersion already exists for this tag,
    # return it (Gitea retries are routine and re-running the processor
    # against the same version snapshot is fine — OCI ingest re-runs are
    # cheap and re-verify the cosign signature). Otherwise create a fresh
    # snapshot of the now-imported module state.
    def find_or_create_version(node_module, tag)
      existing = ::System::NodeModuleVersion
                   .where(node_module: node_module)
                   .where("config->>'git_tag' = ?", tag)
                   .order(version_number: :desc)
                   .first
      return existing if existing

      ::System::NodeModuleVersion.create!(
        node_module: node_module,
        changelog: "Auto-ingested from Gitea tag #{tag}",
        mask:           Array(node_module.mask),
        file_spec:      Array(node_module.file_spec),
        package_spec:   Array(node_module.package_spec),
        protected_spec: Array(node_module.protected_spec),
        config: { "git_tag" => tag }
      )
    end

    def refresh_manifest!(node_module, tag)
      yaml = ::System::ManifestFetchService.fetch(node_module: node_module, ref: tag)
      return [] unless yaml.present?

      result = ::System::ManifestImportService.import!(node_module: node_module, yaml: yaml)
      # ManifestImportService::Result = Struct.new(:ok?, ...) — accessor is `ok?`.
      # The `.success?` typo bubbled a NoMethodError up to process! and aborted
      # the whole publication path (no NodeModuleVersion created), defeating
      # the explicit "non-fatal when manifest yaml fails validation" guard.
      unless result.ok?
        Rails.logger.warn "[ModulePublicationProcessor] manifest re-import failed at tag #{tag}: #{result.error}"
        return []
      end
      node_module.reload
      Rails.logger.info "[ModulePublicationProcessor] manifest refreshed at tag #{tag}: " \
                        "#{result.resolved_dependencies.size} dependency reference(s)"
      result.resolved_dependencies
    end

    # Mirrors module_publications_controller's auto-promote: a publish
    # that survives cosign verification + OCI ingest has already cleared
    # every gate the platform enforces, so withholding current_version_id
    # buys nothing but drift between what's published and what the fleet
    # resolves (agents read node_module.current_version&.artifact; the
    # drift sensor + system_fleet_tool key off current_version&.oci_digest).
    # The non-empty floor, in bytes of the erofs layer. There is no file count
    # available at publish time — the builder's .erofs.meta sidecar carries
    # only fsverity_root and size, and the OCI manifest carries only the layer
    # descriptor — so size is the discriminator we actually have.
    #
    # An empty erofs is not zero bytes: mkfs.erofs on an empty tree still emits
    # a superblock and root inode, a few KiB. The default is set above that and
    # below any module carrying real content. It is deliberately a floor on the
    # SAFE side: withholding promotion from a legitimately tiny module is a
    # visible, recoverable annoyance (the version is still published; an
    # operator can lower the floor or promote by hand), whereas promoting an
    # empty one deletes files off live nodes. Configurable rather than
    # hardcoded so an operator can tune it without a deploy.
    DEFAULT_MIN_ARTIFACT_BYTES = 16_384

    # Class-level so the REST publish path (module_publications_controller)
    # enforces the SAME floor. Two publish paths reach promote_to_version!,
    # and a floor defined twice is a floor that drifts.
    def self.min_artifact_bytes
      configured = ::SiteSetting.get("system.module_publish.min_artifact_bytes")
      value = configured.to_i
      value.positive? ? value : DEFAULT_MIN_ARTIFACT_BYTES
    rescue StandardError
      DEFAULT_MIN_ARTIFACT_BYTES
    end

    # The size THRESHOLD is shared by all three callers; the unknown-size
    # SEMANTICS deliberately are not, and an earlier attempt to unify them was
    # wrong. Recorded here so it is not "cleaned up" again:
    #
    #   fresh publish (promotable_artifact? below) — FAIL CLOSED. An unknown
    #     size cannot be distinguished from a real one, because ingest writes
    #     `fetch(:size_bytes, 0)`, so a failed layer-descriptor read lands as 0
    #     exactly like a genuinely tiny blob. Promoting on that auto-promotes an
    #     artifact nobody measured — plausibly produced by the same broken
    #     pipeline that emitted the empty blob on 2026-08-07. Withholding costs
    #     a visible, recoverable "fleet stays on the old version"; promoting
    #     costs files deleted off live roots.
    #
    #   rollback target (NodeModuleVersion#rollback_usable?) — FAIL OPEN. Old
    #     version rows predate size recording, and refusing them would block
    #     recovery to a version known to have worked.
    #
    # Callers that want the fail-open reading pass their own nil check first.
    def self.artifact_size_promotable?(size_bytes)
      size_bytes.to_i >= min_artifact_bytes
    end

    def min_artifact_bytes
      self.class.min_artifact_bytes
    end

    # nil canonical means ingest produced no artifact for this version at all —
    # previously that STILL promoted, because the promote call sat outside the
    # `if canonical` block that guards the artifact write.
    def promotable_artifact?(canonical)
      return false if canonical.nil?

      self.class.artifact_size_promotable?(canonical.size_bytes)
    end

    # Per-module holdback. DEFAULTS TO TRUE, so a module that says nothing
    # behaves exactly as it did before this existed — this adds a lever, it
    # does not change fleet-wide policy.
    #
    # The empty-artifact floor catches only the degenerate case; a non-empty
    # but broken artifact (wrong arch, truncated tree, a missing binary the
    # units need) still reaches every node the instant it publishes. Full
    # canary/dwell automation is an operator policy decision that would reverse
    # the deliberate auto-promote design documented in
    # module_publications_controller — this is the part of the gap that needs
    # no such decision: an operator can hold a known-risky module back and
    # advance it deliberately (system_rollback_module_version / the
    # staging->blessed promotion path) while everything else keeps flowing.
    #
    # Settable over MCP today: `config` is already in
    # Backed by its OWN COLUMN, not a key on `config`. config is in
    # System::NodeModule::VERSIONED_ATTRIBUTES, so writing it fires the
    # after_update auto_create_version callback — storing the flag there would
    # mean that enabling the holdback itself created a new module version,
    # precisely the event the holdback exists to withhold. (Found by measuring:
    # a two-publish scenario promoted anyway, and the extra version came from
    # the config write, not the publish.) Settable over MCP via
    # system_update_module(module_id:, auto_promote: false).
    #
    # Class-level for the same reason as artifact_size_promotable?: the REST
    # publish path in module_publications_controller must honour the identical
    # flag, and a policy defined twice is a policy that drifts.
    def self.auto_promote?(node_module)
      node_module.auto_promote != false
    end

    # BATCH-ATOMIC PROMOTION. Returns the in-flight multi-module batch this
    # module belongs to, or nil.
    #
    # Publishing auto-promotes per module the moment each build finishes, and
    # build durations inside one batch differ by an order of magnitude
    # (measured 2026-08-28: extension ~2 min, hub-backend ~20 min). A batch
    # spanning core and extension therefore has a GUARANTEED skew window — the
    # window in which ops-hub ran the new extension against the old core, could
    # not boot, and crash-looped for ~25 minutes. Holding each member's
    # promotion until the whole batch lands is the one change that closes it.
    #
    # INFERRED server-side rather than carried on the publish request. The
    # correlation already exists — a member task holds options["batch_id"] and
    # the batch holds module_slugs — and inference works with the builders
    # ALREADY ON THE FLEET. A new wire field would need the very deploy this
    # exists to make safe.
    #
    # Single-module batches and publishes outside any batch are deliberately
    # untouched: there is no sibling to skew against, and the common case
    # should not change.
    #
    # Class-level for the same reason as auto_promote? — both publish paths
    # must apply the identical policy, and a policy defined twice drifts.
    def self.deferring_batch_for(node_module)
      return nil unless node_module.respond_to?(:account_id)
      return nil unless defined?(::System::ModuleBuildBatch)

      ::System::ModuleBuildBatch
        .where(account_id: node_module.account_id)
        .where(status: %w[planning dispatched awaiting_signature publishing])
        .where("planned_count > 1")
        .where("module_slugs @> ?", [ node_module.name ].to_json)
        .order(created_at: :desc)
        .first
    rescue StandardError => e
      # Never let the holdback lookup break a publish: failing OPEN here means
      # today's behaviour (promote), which is the pre-existing state.
      Rails.logger.warn("[ModulePublicationProcessor] deferring_batch_for failed (non-fatal): #{e.class}: #{e.message}")
      nil
    end

    def auto_promote?(node_module)
      self.class.auto_promote?(node_module)
    end

    def hold_promotion_by_policy!(node_module, version, tag)
      Rails.logger.info(
        "[ModulePublicationProcessor] #{node_module.name}@#{tag}: auto_promote is disabled for this " \
        "module; version #{version.id} published but NOT promoted. The fleet keeps the current version " \
        "until it is advanced deliberately."
      )
      emit_promotion_withheld_event(node_module, version, tag, "auto_promote disabled for this module")
    end

    def withhold_promotion!(node_module, version, canonical, tag)
      size = canonical&.size_bytes.to_i
      reason = canonical.nil? ? "ingest produced no artifact" : "artifact is #{size}B, below the #{min_artifact_bytes}B non-empty floor"

      Rails.logger.error(
        "[ModulePublicationProcessor] REFUSING to promote #{node_module.name}@#{tag}: #{reason}. " \
        "Version #{version.id} is published but NOT current; the fleet keeps the previous version."
      )
      emit_promotion_withheld_event(node_module, version, tag, reason)
    end

    # IMP-26b7f0004a49 phase 1 — is this artifact's core (parent
    # powernode-platform) content the core this build was supposed to contain?
    #
    # Only the NATIVE path can answer TODAY: the provenance lives in the OCI
    # manifest annotations ModuleOciIngestService fetched during ingest_native!,
    # and the expectation is recorded on the build batch at dispatch and threaded
    # here through native_build. Every other publish path gets the inert verdict.
    #
    # KNOWN GAP, not an invariant — phase 1 scope, stated so nobody reads the
    # inert return as "those paths are safe". The Gitea-Actions build
    # (.gitea/workflows/build-platform-modules.yaml) runs the same stage15.sh +
    # push.sh, so ITS artifacts carry the same core_source_sha annotation, but it
    # never reaches this service at all: its notify step POSTs to
    # /api/v1/system/module_publications (build-platform-modules.yaml:483 →
    # routes.rb:19 → Api::V1::System::ModulePublicationsController#create), which
    # writes the version + promotes directly and calls only this class's
    # predicates. So there is no ingest, no batch, no expectation to compare
    # against, and it auto-promotes ungated. (Corrected 2026-09-03: this comment
    # previously named worker_api/module_publications_controller, which is the
    # ASYNC hop the Gitea PUSH webhook uses — a different producer.)
    # Closing it needs (a) ingest! to surface oci_annotations the way
    # ingest_native! now does, and (b) a publish-time source for the expected core
    # ref, since there is no dispatch record to carry one.
    def core_provenance_verdict(node_module, result, native_build)
      return ::System::CoreProvenanceGate.inert unless native_build

      ::System::CoreProvenanceGate.evaluate(
        module_name:  node_module.name,
        expected_sha: native_build[:expected_core_sha] || native_build["expected_core_sha"],
        annotations:  result.oci_annotations
      )
    end

    # Same shape as #withhold_promotion! (publish the row, withhold the step
    # that reaches the fleet, emit the high-severity event an operator sees) —
    # the difference is only the reason. A stale-core artifact is not empty and
    # not unsigned; nothing else about it looks wrong, which is exactly why it
    # got two nodes into an outage on 2026-08-15.
    # Same shape again: published, not promoted, event emitted. Only reached
    # when an operator turned module_promotion_require_signature on.
    def withhold_promotion_unsigned!(node_module, version, tag, reason)
      Rails.logger.error(
        "[ModulePublicationProcessor] REFUSING to promote #{node_module.name}@#{tag}: #{reason}. " \
        "Version #{version.id} is published but NOT current; the fleet keeps the previous version."
      )
      emit_promotion_withheld_event(node_module, version, tag, reason)
    end

    def withhold_promotion_for_core_drift!(node_module, version, tag, verdict)
      reason = "core-source provenance #{verdict.state}: #{verdict.reason}"
      # Carry the raw operands, not just the prose. The reason string is
      # rendered for a human and abbreviates; an operator diagnosing a refusal
      # needs the values that were actually compared.
      provenance = {
        state:        verdict.state,
        expected_sha: verdict.expected_sha,
        actual_sha:   verdict.actual_sha,
        actual_remote: verdict.actual_remote
      }.compact

      Rails.logger.error(
        "[ModulePublicationProcessor] REFUSING to promote #{node_module.name}@#{tag}: #{reason}. " \
        "Version #{version.id} is published but NOT current; the fleet keeps the previous version. " \
        "Set #{::System::CoreProvenanceGate::ENABLED_SETTING}=false to override."
      )
      emit_promotion_withheld_event(node_module, version, tag, reason, provenance: provenance)
    end

    def emit_promotion_withheld_event(node_module, version, tag, reason, provenance: nil)
      return unless defined?(::System::Fleet::EventBroadcaster)

      ::System::Fleet::EventBroadcaster.emit!(
        account: node_module.account,
        kind: "system.module_promotion_withheld",
        # high: this is the signal that the 2026-08-07 incident had no
        # equivalent of — every platform signal read healthy while a bad
        # artifact reached the fleet. A withheld promotion means a build
        # produced nothing usable and wants a human.
        severity: :high,
        source: "module_publication_processor",
        node_module_id: node_module.id,
        node_module_version_id: version.id,
        payload: {
          module_name:    node_module.name,
          version_number: version.version_number,
          git_tag:        tag,
          reason:         reason
        }.merge(provenance.present? ? { core_provenance: provenance } : {})
      )
    rescue StandardError => e
      Rails.logger.warn("[ModulePublicationProcessor] promotion-withheld event failed: #{e.message}")
    end

    def promote_current_version(node_module, version)
      # Writes current_version_id AND the denormalized current_version_number
      # atomically (idempotent) — never just the id, which drifts the number the
      # drift sensor / fleet reconciler / UI read. See NodeModule#promote_to_version!.
      node_module.promote_to_version!(version)
    end

    def register_skills_for(node_module)
      return unless defined?(::System::ModuleSkillRegistrar)
      result = ::System::ModuleSkillRegistrar.register_for_module!(node_module: node_module)
      # ModuleSkillRegistrar::Result = Struct.new(:ok?, ...) — the accessor
      # is `ok?`, not `success?`. The mismatch was getting swallowed by the
      # rescue below, masking failures (and tripping the gitea_module_spec
      # registrar mock which exposes the matching `ok?` shape).
      unless result.ok?
        Rails.logger.warn "[ModulePublicationProcessor] skill registration failed: #{result.error}"
      end
    rescue StandardError => e
      Rails.logger.warn "[ModulePublicationProcessor] skill registrar raised: #{e.class}: #{e.message}"
    end

    def emit_published_event(node_module, version, oci_ref, artifacts, tag, promoted)
      return unless defined?(::System::Fleet::EventBroadcaster)

      ::System::Fleet::EventBroadcaster.emit!(
        account: node_module.account,
        kind: "system.module_published",
        severity: :low,
        source: "gitea_webhook",
        node_module_id: node_module.id,
        node_module_version_id: version.id,
        payload: {
          module_name:    node_module.name,
          version_number: version.version_number,
          git_tag:        tag,
          oci_ref:        oci_ref,
          arches:         artifacts.map(&:architecture),
          promoted:       promoted
        }
      )
    rescue StandardError => e
      Rails.logger.warn "[ModulePublicationProcessor] fleet event emit failed: #{e.class}: #{e.message}"
    end

    def emit_publish_failed_event(node_module, tag, error_message)
      return unless defined?(::System::Fleet::EventBroadcaster)

      ::System::Fleet::EventBroadcaster.emit!(
        account: node_module.account,
        kind: "system.module_publish_failed",
        severity: :high,
        source: "gitea_webhook",
        node_module_id: node_module.id,
        payload: {
          module_name: node_module.name,
          git_tag:     tag,
          error:       error_message
        }
      )
    rescue StandardError => e
      Rails.logger.warn "[ModulePublicationProcessor] fleet event (failure) emit failed: #{e.class}: #{e.message}"
    end
  end
end
