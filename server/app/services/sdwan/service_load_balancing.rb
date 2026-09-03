# frozen_string_literal: true

module Sdwan
  # Operator-tunable load-balancer defaults for the Traefik config
  # Sdwan::ServiceExposureWriter emits for a MULTI-backend service (APO-3c).
  #
  # Three-tier resolution, mirroring Sdwan::NetworkHygieneService.default_ttl_seconds:
  #
  #   1. the service's own `metadata["load_balancer"][<key>]`
  #   2. the account's `settings["system.sdwan.service_load_balancing.<key>"]`
  #   3. the deployment-wide SiteSetting of the same key
  #   4. the constant below
  #
  # Tier 1 exists because a health-check PATH is not a deployment-wide fact: a
  # Grafana replica answers /api/health, a Rails app /up, a bare exporter /.
  # A single global path applied to every scaled service would mark healthy
  # backends down.
  #
  # Which is why health checking is OPT-IN (DEFAULT_HEALTH_CHECK_ENABLED =
  # false) and why the writer asks about it only for a service with an explicit
  # multi-member backend set. Traefik drops a check-failing server from the pool
  # and answers 503 once none are left, so a wrong path does not degrade a
  # scaled service — it takes the WHOLE service dark, which is strictly worse
  # than the single unchecked backend it replaced. Turning it on is therefore a
  # deliberate act by whoever knows the path: set
  # `health_check_enabled: true` (plus `health_check_path`) on the service's
  # metadata, the account's settings, or the SiteSetting, in that order of
  # precedence.
  #
  # NOTE (APO-3c/APO-4): every tier is reachable. `system_set_service_backends`
  # (Ai::Tools::SystemIngressTool, IMP-0c10b9fd5596) writes the backend set AND
  # the per-service `metadata["load_balancer"]` overrides that tier 1 reads;
  # it is the only MCP door onto either. Tiers 2 and 3 are the account
  # settings and the SiteSetting.
  module ServiceLoadBalancing
    SETTING_PREFIX = "system.sdwan.service_load_balancing"

    DEFAULT_HEALTH_CHECK_ENABLED  = false
    DEFAULT_HEALTH_CHECK_PATH     = "/"
    DEFAULT_HEALTH_CHECK_INTERVAL = "10s"
    DEFAULT_HEALTH_CHECK_TIMEOUT  = "3s"

    class << self
      # The Traefik `loadBalancer.healthCheck` hash for this service, or nil when
      # health checking is switched off. Callers decide WHETHER to ask (the
      # writer only asks for a multi-backend service); this decides what it
      # looks like.
      def health_check_for(service, account: nil)
        return nil unless health_check_enabled?(service, account: account)

        {
          "path"     => setting(service, "health_check_path", DEFAULT_HEALTH_CHECK_PATH, account: account),
          "interval" => setting(service, "health_check_interval", DEFAULT_HEALTH_CHECK_INTERVAL, account: account),
          "timeout"  => setting(service, "health_check_timeout", DEFAULT_HEALTH_CHECK_TIMEOUT, account: account)
        }
      end

      def health_check_enabled?(service, account: nil)
        raw = raw_setting(service, "health_check_enabled", account: account)
        return DEFAULT_HEALTH_CHECK_ENABLED if raw.nil?

        ActiveModel::Type::Boolean.new.cast(raw) ? true : false
      end

      private

      def setting(service, suffix, fallback, account: nil)
        raw = raw_setting(service, suffix, account: account)
        raw.nil? ? fallback : raw.to_s
      end

      # First tier that actually holds a value, else nil.
      #
      # `false` is a VALUE here, not an absence: a per-service
      # `health_check_enabled: false` must beat a deployment default of true,
      # which a `.presence ||` chain would silently drop on the floor. So each
      # tier is rejected only when it is nil or an empty string, never on
      # falsiness.
      def raw_setting(service, suffix, account: nil)
        [
          service_override(service, suffix),
          account_override(account || service&.account, suffix),
          site_setting(suffix)
        ].each { |candidate| return candidate if present_value?(candidate) }

        nil
      end

      def present_value?(value)
        !value.nil? && !(value.is_a?(String) && value.strip.empty?)
      end

      def service_override(service, suffix)
        metadata = service.respond_to?(:metadata) ? service.metadata : nil
        return nil unless metadata.is_a?(Hash)

        metadata.dig("load_balancer", suffix)
      end

      def account_override(account, suffix)
        return nil unless account.respond_to?(:settings)

        account.settings&.dig("#{SETTING_PREFIX}.#{suffix}")
      end

      def site_setting(suffix)
        ::SiteSetting.get("#{SETTING_PREFIX}.#{suffix}")
      rescue StandardError
        nil
      end
    end
  end
end
