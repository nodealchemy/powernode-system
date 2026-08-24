# frozen_string_literal: true

module Api
  module V1
    module System
      module NodeApi
        # Module data endpoint for node instances
        # Provides modules assigned to the instance's node
        class ModulesController < BaseController
          before_action :set_module, only: [ :show, :download, :resource ]

          # GET /api/v1/system/node_api/modules
          # List modules assigned to this node with dependencies resolved
          def index
            modules = node_modules.enabled.includes(:category, :dependencies)
            resolved_modules = resolve_module_dependencies(modules)

            # FAIL CLOSED on an incomplete list.
            #
            # This response is the agent's ONLY statement of desired state, and
            # a module missing from it is indistinguishable — to the agent —
            # from one the operator genuinely unassigned. It reconciles the
            # difference by DETACHING, stopping the module's services. On
            # 2026-07-28 ops-hub acted on a list missing its own platform
            # modules and detached rails/traefik/sidekiq: the services that
            # serve this very endpoint. Self-hosted, that is unrecoverable —
            # the list that would say "re-attach" is served by what was just
            # detached. It took a reboot.
            #
            # Only the server can tell "incomplete" from "unassigned", and only
            # here, while it still holds both the input and the output. So the
            # invariant is asserted at the one place it is checkable:
            # resolution REORDERS, it must never change the population.
            #
            # 503 rather than 500 because this is explicitly retryable, and
            # because the agent already treats any non-2xx as "could not
            # determine desired state" and skips the tick without detaching
            # (observed during that incident: a 502 caused no detach). An
            # honest error is strictly safer than a confident wrong answer.
            unless resolution_complete?(modules, resolved_modules)
              ::Rails.logger.error(
                "[NodeApi::Modules] incomplete resolution for node #{current_node&.id}: " \
                "#{modules.size} assigned -> #{resolved_modules.size} resolved; refusing to serve partial desired state"
              )
              return render_error(
                "module dependency resolution returned an incomplete list; refusing to serve a partial desired state",
                status: :service_unavailable,
                code: "incomplete_module_resolution"
              )
            end

            render_success(
              modules: resolved_modules.map { |m| ::System::NodeModuleNodeApiSerializer.new(m).summary },
              count: resolved_modules.size,
              # The node's operator-facing name (e.g. "ops-hub") — the agent
              # persists this and applies it as the hostname (etcidentity), so a
              # node with no fw-cfg instance_name still gets the right hostname
              # before DHCP/DNS. See agent runtime/hostname.go.
              hostname: current_node&.name,
              # Boot-LKG config (#39 Level-1 boot-independence). The agent stamps
              # these onto the boot breadcrumb → frozen last-known-good at capture.
              # All 0/"" when unset → the agent uses its compile-time defaults /
              # kernel-cmdline overrides. Config-driven, no hardcoded values here.
              #
              # - staleness threshold: at a fallback boot, age past this → ALERT,
              #   never block. See agent runtime/lkg.go stalenessThreshold().
              # - app-health probe url/N/window: the promotion gate the post-boot
              #   capturer uses (composed /up 200 ×N). Delivering it here lets us
              #   later strengthen the gate (e.g. a composed-API check) with NO new
              #   agent binary. See agent runtime/lkg_capture.go resolveGate().
              lkg_staleness_threshold_seconds:      boot_lkg_setting_int("staleness_threshold_seconds"),
              lkg_app_health_url:                   ::SiteSetting.get("system.boot_lkg.app_health_url").to_s.presence,
              lkg_app_health_required_consecutive:  boot_lkg_setting_int("app_health_required_consecutive"),
              lkg_app_health_poll_interval_seconds: boot_lkg_setting_int("app_health_poll_interval_seconds"),
              # Hostnames the agent must ALWAYS be able to reach, regardless of
              # any individual module's own egress_allow policy (e.g. a hub's
              # own Gitea host — needed by DevCellBootstrapService's deploy-key
              # provisioning + disk-image CI, but not something to bake as a
              # static IP into a module manifest; real infra hosts belong in
              # config, not tracked source). Resolved fresh on EVERY node_api
              # poll (not just at agent boot) so the agent's own DNS resolution
              # in ApplyEgressAllowlistWithProtected picks up changes without a
              # restart. Config-driven, no hardcoded values here — see
              # #protected_egress_hosts.
              protected_egress_hosts: protected_egress_hosts,
              # Operator-approved allowlist of module identifiers permitted to
              # run with security.privileged=true (which disables ALL on-node
              # confinement). A module manifest can only REQUEST privileged; this
              # list is the GRANT the agent's apply-side gate checks before
              # honouring it (IMP-01a02f70-20b1, agent buildPolicy +
              # privilegedApproved). Sourced from an admin-gated account setting /
              # SiteSetting — NEVER from the module manifest — so a compromised
              # module cannot self-approve. Default empty = deny. Refetched every
              # poll like #protected_egress_hosts so an operator approval (or
              # revocation) takes effect on the next reconcile with no agent
              # restart. Values are matched against a module's id AND name.
              privileged_module_ids: privileged_module_ids(resolved_modules)
            )
          end

          # GET /api/v1/system/node_api/modules/:id
          # Get specific module details
          #
          # Response shape: render_success splats the serialized fields at
          # data.* (NOT data.module.*) so the agent's manifest.FetchAndCache
          # can decode `data` directly into its Manifest struct. Wrapping
          # under `data.module` produced an empty Manifest (no top-level
          # id/name/digest), tripping writeCache's "nil or empty ID" guard
          # and starving the reconciler of any actionable data.
          def show
            render_success(**::System::NodeModuleNodeApiSerializer.new(@module).full)
          end

          # GET /api/v1/system/node_api/modules/:id/download
          # Get module data file download info, including the OCI
          # registry coordinates when the M1 publish pipeline has
          # produced an artifact.
          #
          # Returns the erofs artifact metadata. The agent's
          # internal/oci.Puller consumes the `file` block for
          # streaming + sha256 verify and the `oci` block for cosign
          # material.
          def download
            artifact = @module.current_version&.artifact
            return render_error("Module has no published artifact") unless artifact

            render_success(
              file: ::System::NodeModuleNodeApiSerializer.new(@module).file_payload(artifact),
              oci:  {
                ref:                artifact["oci_ref"],
                digest:             artifact["oci_digest"],
                fsverity_root_hash: artifact["fsverity_root"],
                size_bytes:         artifact["size"]
              }
            )
          end

          # GET /api/v1/system/node_api/modules/:id/rsync_spec
          # Returns the platform-rendered rsync filter file as plain
          # text. The agent's commit CLI consumes this when capturing
          # an upper-layer delta — server-side rendering centralizes
          # the cross-neighbor effective_mask logic so the agent
          # doesn't have to reimplement it.
          #
          # Phase 2 of the agent stub implementation plan; currently
          # used by future commit CLI (Phase 4) but exposed in Phase
          # 2 alongside the attach/detach surface so all module-
          # lifecycle commands have a uniform metadata source.
          def rsync_spec
            render plain: @module.rsync_spec(target: current_instance),
                   content_type: "text/plain"
          end

          # GET /api/v1/system/node_api/modules/:id/:resource
          # Get specific module resource
          def resource
            resource_name = params[:resource]

            # Check if module has the requested resource
            resource_data = @module.config&.dig("resources", resource_name)

            if resource_data.blank?
              return render_not_found("ModuleResource")
            end

            render_success(
              module_id: @module.id,
              resource: resource_name,
              data: resource_data
            )
          end

          private

          # Integer boot-LKG SiteSetting under the "system.boot_lkg." namespace.
          # Returns 0 when unset (the agent then uses its own compile-time default
          # / cmdline override) — config-driven with no hardcoded value here.
          def boot_lkg_setting_int(suffix)
            (::SiteSetting.get("system.boot_lkg.#{suffix}").presence || 0).to_i
          end

          # Account → global cascade (mirrors System::Fleet::PromotionCriteria's
          # resolution style, minus the per-module layer — this setting is
          # deployment-level, not something an individual module should
          # override). Empty array when neither is configured — no behavior
          # change for accounts that never set this.
          def protected_egress_hosts
            raw = current_account&.settings&.dig("protected_egress_hosts")
            raw = SiteSetting.get("protected_egress_hosts") if raw.blank?
            Array(raw).map(&:to_s).map(&:strip).reject(&:blank?)
          end

          # Account → global cascade (same shape as #protected_egress_hosts).
          # The operator's list of modules approved to run
          # security.privileged=true. This is the ONLY grant the agent's
          # privileged gate honours; the module manifest cannot contribute to
          # it. Empty when unset — the agent then refuses every privileged
          # module (default-deny), so a node whose modules genuinely need
          # privileged (e.g. dev-cell) must have those modules listed here.
          # Kept out of the module manifest deliberately: an admin-gated setting
          # is the operator acknowledgement, so approval cannot travel with a
          # module that merely declares itself privileged.
          #
          # Operators MAY configure entries by human-friendly module NAME or by
          # NodeModule id. We RESOLVE them here, against the modules actually
          # resolved for THIS node, down to NodeModule ids — the immutable,
          # server-assigned UUIDv7 the agent keys its gate on. The agent
          # therefore never matches on a mutable/author-influenced name (review
          # finding F1): name→id resolution is done here where the authoritative
          # NodeModule records live, so two modules sharing a name can never both
          # inherit an approval — only the id(s) present on this node are emitted.
          def privileged_module_ids(resolved_modules)
            raw = current_account&.settings&.dig("privileged_module_ids")
            raw = SiteSetting.get("privileged_module_ids") if raw.blank?
            configured = Array(raw).map(&:to_s).map(&:strip).reject(&:blank?).to_set
            return [] if configured.empty?

            resolved_modules.filter_map do |m|
              id = m.id.to_s
              id if configured.include?(id) || configured.include?(m.name.to_s)
            end.uniq
          end

          def set_module
            @module = node_modules.find(params[:id])
          rescue ActiveRecord::RecordNotFound
            render_record_not_found("NodeModule")
          end

          def node_modules
            # Two pathways for "module on this node":
            #
            # 1. Base modules — explicit NodeModuleAssignment row pointing at
            #    this node. These are the subscription-variety / standalone
            #    modules the operator attached.
            # 2. Dependant children — config-variety or instance-variety
            #    modules created via NodeModuleAssignment#create_dependant!.
            #    These have parent_module_id set and node_id pointing at this
            #    node directly; no assignment row is created (the
            #    parent_module + node FK pair already scopes them).
            #
            # The agent needs to see both. Earlier the query only honored
            # path 1, so dependant children were silently absent from the
            # on-node module list.
            assigned_ids = ::System::NodeModuleAssignment
                           .where(node_id: current_node.id, enabled: true)
                           .pluck(:node_module_id)

            dependant_ids = ::System::NodeModule
                            .where(node_id: current_node.id, enabled: true)
                            .where.not(parent_module_id: nil)
                            .pluck(:id)

            ::System::NodeModule.where(id: (assigned_ids + dependant_ids).uniq)
          end

          # Resolution is a topological REORDERING, so the set of ids going in
          # must equal the set coming out. Comparing sorted ids catches both
          # directions of corruption: a dropped module (the dangerous one — it
          # reads as an unassignment and triggers a detach) and a duplicated
          # one (which would make the agent's digest diff incoherent).
          def resolution_complete?(input, resolved)
            input.map(&:id).sort == resolved.map(&:id).sort
          end

          def resolve_module_dependencies(modules)
            # Simple topological sort based on dependencies
            resolved = []
            visited = Set.new
            temp_visited = Set.new

            modules.each do |mod|
              visit_module(mod, modules, resolved, visited, temp_visited)
            end

            resolved
          end

          def visit_module(mod, available_modules, resolved, visited, temp_visited)
            return if visited.include?(mod.id)

            if temp_visited.include?(mod.id)
              # Circular dependency detected, skip but log
              Rails.logger.warn "Circular dependency detected for module #{mod.id}"
              return
            end

            temp_visited.add(mod.id)

            mod.dependencies.each do |dep|
              if available_modules.map(&:id).include?(dep.id)
                visit_module(dep, available_modules, resolved, visited, temp_visited)
              end
            end

            temp_visited.delete(mod.id)
            visited.add(mod.id)
            resolved << mod
          end
        end
      end
    end
  end
end
