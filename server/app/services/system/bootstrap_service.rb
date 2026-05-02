# frozen_string_literal: true

module System
  # Composes BootstrapToken issuance + CA chain resolution + image_base
  # selection + iPXE script rendering. Used by:
  #
  #   - NetbootController GET /netboot/:instance_id/script.ipxe
  #   - LocalQemuProvider during create_instance (delegates to CloudSeed
  #     internally; this service is the operator-facing entry point)
  #   - Concierge "give me a one-line install command for this instance"
  #
  # Reference: Golden Eclipse plan M0 + M3 — combines BootstrapToken
  # issuance with NetbootService's iPXE template rendering.
  class BootstrapService
    Result = Struct.new(:ok?, :script, :token_id, :error, keyword_init: true)

    def self.render_for_instance(instance:, image_base: nil, ttl: 1.hour, purpose: "netboot")
      new.render_for_instance(
        instance: instance,
        image_base: image_base,
        ttl: ttl,
        purpose: purpose
      )
    end

    def render_for_instance(instance:, image_base:, ttl:, purpose:)
      raise ArgumentError, "instance: required" unless instance.is_a?(::System::NodeInstance)

      token, plaintext = ::System::BootstrapToken.issue!(
        node: instance.node,
        node_instance: instance,
        intended_subject: instance.id,
        ttl: ttl,
        purpose: purpose
      )

      script = ::System::NetbootService.render_ipxe_script(
        instance: instance,
        bootstrap_token: plaintext,
        image_base: resolve_image_base(image_base),
        ca_pem_url: ca_pem_url,
        ca_pem_inline: ca_pem_url.nil? ? ca_pem_inline : nil
      )

      Result.new(ok?: true, script: script, token_id: token.id)
    rescue ActiveRecord::RecordInvalid, ArgumentError => e
      Result.new(ok?: false, error: e.message)
    rescue StandardError => e
      Rails.logger.error("[BootstrapService] #{e.class}: #{e.message}")
      Result.new(ok?: false, error: e.message)
    end

    private

    def resolve_image_base(provided)
      provided || ENV["POWERNODE_IMAGE_BASE"] ||
        "#{platform_url}/.well-known/powernode/images"
    end

    def platform_url
      ENV["POWERNODE_PLATFORM_URL"] ||
        (Rails.env.production? ? "https://platform.local" : "http://localhost:3000")
    end

    # Prefer a URL pointer to the CA chain (kernel cmdline has a ~2 KB
    # limit; multi-cert chains overflow). Inline only when
    # POWERNODE_CA_PEM_URL is unset, e.g. dev/test.
    def ca_pem_url
      ENV["POWERNODE_CA_PEM_URL"]
    end

    def ca_pem_inline
      ENV["POWERNODE_CA_PEM"] ||
        "-----BEGIN CERTIFICATE-----\nFIXTURE\n-----END CERTIFICATE-----"
    end
  end
end
