# frozen_string_literal: true

module System
  # Sparse lookup mapping a platform component (api/worker/frontend/etc.)
  # to its NodeTemplate + allocated SDWAN VirtualIP. Federation peers and
  # the Sidekiq worker call `Powernode::Bootstrap.discover_peer(:api)` at
  # startup to learn what VIP to dial.
  #
  # Plan reference: Decentralized Federation §G, P2.
  class PlatformDeployment < BaseRecord
    include System::Base

    SERVICE_ROLES = %w[
      api
      worker
      frontend
      postgres
      redis
      reverse-proxy
      satellite-runtime
    ].freeze

    # ---- Declared scaling window (IMP-f986d379120a, bulk review D16) -----
    #
    # The deployment-side twin of Ai::Mission#scaling_bounds (APO-3a): the
    # replica range inside which System::Platform::ReplicaReconciler may scale
    # this deployment OUT without a person looking. The reconciler resolves
    # `system.platform.scale_out` and, when that policy auto-executes, applies
    # the scale-out only if the target sits inside this window — outside it the
    # pass PARKS (provisions nothing and says why) rather than clamping, which
    # would silently rewrite the operator's number. Scale-IN is never released
    # by this window; it has its own category and an irreversibility rule.
    #
    # The keys a deployment declares them under, inside `metadata`. Both are
    # OPTIONAL: an undeclared bound resolves through the settings ladder below,
    # Ai::Mission.resolve_scale_bound — the same presence-decisive, fail-closed
    # walk the project window uses, so the two homes cannot drift apart.
    MIN_REPLICAS_METADATA_KEY = "auto_scale_min_replicas"
    MAX_REPLICAS_METADATA_KEY = "auto_scale_max_replicas"

    # DB-driven config: deployment `metadata` → Account#settings → SiteSetting
    # → the constant below. Keyed under the PLATFORM namespace, beside the
    # reconciler's own `system.platform.replica_reconcile_max_delta`, and
    # deliberately NOT under the project keys (`ai.provisioning.*`): a platform
    # component's replica ceiling and a project's are different budgets, and
    # one SiteSetting that widened both at once would let a project-level opt-in
    # open unattended platform provisioning nobody asked for.
    MIN_REPLICAS_SETTING = "system.platform.auto_scale_min_replicas"
    MAX_REPLICAS_SETTING = "system.platform.auto_scale_max_replicas"

    # Last-resort rungs, shared with the project window on purpose: the floor
    # is the platform minimum a deployment may raise but never lower, and the
    # ceiling is the NON-CEILING (0 = "nothing declared anywhere"), so an
    # install that declares no window gets no unattended scale-out — the
    # operator opts in per deployment, per account, or fleet-wide.
    DEFAULT_AUTO_SCALE_MIN_REPLICAS = ::Ai::Mission::DEFAULT_AUTO_SCALE_MIN_REPLICAS
    DEFAULT_AUTO_SCALE_MAX_REPLICAS = ::Ai::Mission::DEFAULT_AUTO_SCALE_MAX_REPLICAS

    belongs_to :node_template, class_name: "System::NodeTemplate"
    belongs_to :virtual_ip, class_name: "Sdwan::VirtualIp", optional: true

    attribute :metadata, :jsonb, default: -> { {} }

    validates :name, presence: true, length: { maximum: 100 },
                     uniqueness: { scope: :account_id, case_sensitive: false }
    validates :service_role, inclusion: { in: SERVICE_ROLES }
    validates :target_replicas, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :public_dns_hostname, length: { maximum: 256 }, allow_nil: true
    validates :satellite_extension_slug, length: { maximum: 64 }, allow_nil: true

    scope :by_role,        ->(role) { where(service_role: role) }
    scope :with_vip,       -> { where.not(virtual_ip_id: nil) }
    scope :public_facing,  -> { where.not(public_dns_hostname: nil) }
    scope :for_satellite,  ->(slug) { where(satellite_extension_slug: slug) }
    scope :for_mainline,   -> { where(satellite_extension_slug: nil) }

    # This deployment's declared scaling window, as an Ai::Mission::ScalingBounds
    # so the reconciler's gate and the adaptation composer speak one vocabulary
    # (`auto_scale_out?`, `permits_replica_count?`). The floor is clamped UP to
    # DEFAULT_AUTO_SCALE_MIN_REPLICAS; the ceiling is taken as declared — the
    # reconciler's per-pass clamp already caps what one pass may reach, and
    # rewriting the operator's number here would be a silent overrule.
    def scaling_bounds
      ::Ai::Mission::ScalingBounds.new(
        min: [ resolved_scale_bound(MIN_REPLICAS_METADATA_KEY, MIN_REPLICAS_SETTING,
                                    DEFAULT_AUTO_SCALE_MIN_REPLICAS),
               DEFAULT_AUTO_SCALE_MIN_REPLICAS ].max,
        max: resolved_scale_bound(MAX_REPLICAS_METADATA_KEY, MAX_REPLICAS_SETTING,
                                  DEFAULT_AUTO_SCALE_MAX_REPLICAS)
      )
    end

    # Returns the preferred dial target for this deployment.
    # VIP wins over public DNS — VIP is overlay-routed (lower latency,
    # survives WAN outage); DNS is for bootstrap before joining the mesh.
    def preferred_endpoint
      return virtual_ip.cidr.split("/").first if virtual_ip
      public_dns_hostname
    end

    # Resolution order used by Federation::EndpointProber for federation
    # peer dialing (Plan §J Endpoint Discovery): VIP first, DNS second.
    # Returns an array of { url, scope } records, priority-ordered.
    def dial_candidates(port: nil)
      candidates = []
      if virtual_ip && (host = virtual_ip.cidr&.split("/")&.first)
        candidates << { url: scheme_and_host(host, port), scope: :sdwan }
      end
      if public_dns_hostname
        candidates << { url: scheme_and_host(public_dns_hostname, port), scope: :wan }
      end
      candidates
    end

    private

    def scheme_and_host(host, port)
      port_segment = port ? ":#{port}" : ""
      "https://#{host}#{port_segment}"
    end

    # The resolution ladder, most specific first — lazy, so a deployment that
    # answers on its own metadata never reads a SiteSetting. Tolerant of a
    # symbol-keyed metadata hash held in memory, the way the project ladder is.
    def resolved_scale_bound(metadata_key, setting_key, default)
      rungs = [
        [ "the deployment's metadata", -> { metadata_window[metadata_key] } ],
        [ "the account's settings", -> { ::Ai::FableRouting.setting(account, setting_key) } ],
        [ "SiteSetting #{setting_key}", -> { ::Ai::FableRouting.global_setting(setting_key) } ]
      ]
      ::Ai::Mission.resolve_scale_bound(rungs, key: metadata_key, default: default)
    end

    def metadata_window
      metadata.is_a?(Hash) ? metadata.deep_stringify_keys : {}
    end
  end
end
