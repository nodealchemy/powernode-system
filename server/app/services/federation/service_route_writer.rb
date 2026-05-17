# frozen_string_literal: true

require "yaml"
require "fileutils"

module Federation
  # Subscriber-side writer: generates Traefik dynamic configuration
  # from active ServiceSubscription rows. One YAML file per account
  # in the dynamic-config directory; Traefik file-watches and reloads.
  #
  # Per-subscription output shape:
  #
  #   HTTP/HTTPS subscription:
  #     http:
  #       routers:
  #         sub-<id>:
  #           rule: Host(`<local_hostname>`)
  #           service: sub-<id>-backend
  #           middlewares: [sub-<id>-grant]
  #           tls: { certResolver: letsencrypt } (https only)
  #       services:
  #         sub-<id>-backend:
  #           loadBalancer:
  #             servers: [{ url: <scheme>://<backend_vip>:<backend_port> }]
  #             passHostHeader: false
  #       middlewares:
  #         sub-<id>-grant:
  #           headers:
  #             customRequestHeaders:
  #               Authorization: Bearer <federation_grant_token>
  #
  #   TCP/TLS subscription:
  #     tcp:
  #       routers:
  #         sub-<id>:
  #           rule: HostSNI(`<local_hostname>`) | HostSNI(`*`)
  #           service: sub-<id>-backend
  #           tls: {} (tls protocol only)
  #       services:
  #         sub-<id>-backend:
  #           loadBalancer:
  #             servers: [{ address: <backend_vip>:<backend_port> }]
  #
  # Site-local subscriptions (powernode-tcp-forwarder) are EXCLUDED
  # — they don't go through Traefik. They get their own config writer
  # (P4.6.7) targeting the forwarder daemon.
  #
  # Plan reference: Decentralized Federation §L.4 + P4.6.3.
  class ServiceRouteWriter
    class WriteError < StandardError; end

    DEFAULT_DYNAMIC_DIR = "/etc/traefik/dynamic"

    class << self
      def write!(account:, dynamic_dir: DEFAULT_DYNAMIC_DIR)
        new(account: account, dynamic_dir: dynamic_dir).write!
      end
    end

    def initialize(account:, dynamic_dir:)
      @account = account
      @dynamic_dir = dynamic_dir
    end

    def write!
      subs = active_traefik_subs
      yaml = render_yaml(subs)

      FileUtils.mkdir_p(@dynamic_dir)
      output_path = File.join(@dynamic_dir, "service-subscriptions-#{@account.id}.yaml")
      File.write(output_path, yaml)

      { output_path: output_path, route_count: subs.size }
    rescue StandardError => e
      raise WriteError, "ServiceRouteWriter failed: #{e.class}: #{e.message}"
    end

    # Renders the YAML hash that Traefik consumes. Public for testability.
    def render_yaml(subs)
      http_routers = {}
      http_services = {}
      http_middlewares = {}
      tcp_routers = {}
      tcp_services = {}

      subs.each do |sub|
        case sub.protocol
        when "https", "http"
          add_http_route!(sub, http_routers, http_services, http_middlewares)
        when "tcp", "tls"
          add_tcp_route!(sub, tcp_routers, tcp_services)
        end
      end

      top = {}
      if http_routers.any?
        top["http"] = {
          "routers" => http_routers,
          "services" => http_services
        }
        top["http"]["middlewares"] = http_middlewares if http_middlewares.any?
      end
      if tcp_routers.any?
        top["tcp"] = { "routers" => tcp_routers, "services" => tcp_services }
      end

      YAML.dump(top)
    end

    private

    def active_traefik_subs
      ::System::Federation::ServiceSubscription
        .where(account: @account, status: "active")
        .reject(&:site_local?)
    end

    def add_http_route!(sub, routers, services, middlewares)
      router_key = "sub-#{sub.id}"
      service_key = "#{router_key}-backend"
      middleware_key = "#{router_key}-grant"

      router = {
        "rule" => "Host(`#{sub.local_hostname}`)",
        "service" => service_key,
        "middlewares" => [ middleware_key ]
      }
      router["tls"] = { "certResolver" => "letsencrypt" } if sub.protocol == "https"
      routers[router_key] = router

      services[service_key] = {
        "loadBalancer" => {
          "servers" => [ { "url" => http_backend_url(sub) } ],
          "passHostHeader" => false
        }
      }

      middlewares[middleware_key] = {
        "headers" => {
          "customRequestHeaders" => {
            "Authorization" => "Bearer #{sub.federation_grant.bearer_token}"
          }
        }
      }
    end

    def add_tcp_route!(sub, routers, services)
      router_key = "sub-#{sub.id}"
      service_key = "#{router_key}-backend"

      router = {
        "rule" => "HostSNI(`#{sub.local_hostname}`)",
        "service" => service_key
      }
      router["tls"] = {} if sub.protocol == "tls"
      routers[router_key] = router

      services[service_key] = {
        "loadBalancer" => {
          "servers" => [ { "address" => "#{sub.backend_vip}:#{sub.backend_port}" } ]
        }
      }
    end

    def http_backend_url(sub)
      scheme = sub.protocol == "https" ? "https" : "http"
      "#{scheme}://#{sub.backend_vip}:#{sub.backend_port}"
    end
  end
end
