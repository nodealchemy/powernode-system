# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Skill: regenerate the reverse-proxy (Traefik) dynamic config for a
      # single certificate's account.
      #
      # Thin wrapper over `Acme::TraefikConfigWriter.write!` — given a valid
      # AcmeCertificate, it re-emits the account's Traefik dynamic YAML so the
      # cert's routers (API / Cable / frontend) come online. The writer
      # file-watches the dynamic dir, so writing the YAML is the whole job:
      # Traefik reloads automatically.
      #
      # Intentionally narrow: it only regenerates from the account's valid
      # certs. It does NOT mutate ENV or override proxy backend/frontend URLs —
      # those are deployment-level concerns owned by powernode-reverse-proxy.sh
      # and the static-config writer, not a per-cert skill.
      #
      # Plan reference: chat-driven platform deployment + maintenance
      # (reverse-proxy composition).
      class ReverseProxyComposeExecutor < BaseSkillExecutor
        skill_descriptor(
          name: "reverse_proxy_compose",
          description: "Regenerate the reverse-proxy (Traefik) dynamic config for a certificate's account. Use this skill when an operator wants a valid certificate's HTTPS routers brought online (or refreshed) in the reverse proxy — it re-emits the account's dynamic YAML from its valid certs; Traefik file-watches and reloads automatically.",
          category: "devops",
          inputs: {
            certificate_id: { type: "string", required: true,
                              description: "AcmeCertificate id (must be status=valid) whose account's reverse-proxy config to regenerate" }
          },
          outputs: {
            certificate_id: :string,
            common_name: :string,
            status: :string,
            dynamic_config_path: :string,
            routers_configured: :integer
          }
        )

        binds_to "System Concierge"

        protected

        def perform(certificate_id:)
          cert = ::System::AcmeCertificate.find_by(id: certificate_id, account: @account)
          return failure("Certificate not found: #{certificate_id}") unless cert
          unless cert.status == "valid"
            return failure("Certificate status=#{cert.status} — cannot compose reverse-proxy config (must be valid)")
          end

          result = ::Acme::TraefikConfigWriter.write!(account: @account)

          success(
            certificate_id: cert.id,
            common_name: cert.common_name,
            status: cert.status,
            dynamic_config_path: result[:output_path],
            routers_configured: result[:cert_count]
          )
        end
      end
    end
  end
end
