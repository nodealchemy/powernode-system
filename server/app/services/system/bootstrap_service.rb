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

      # Preflight BEFORE minting: a missing CA / platform_url / image_base must not
      # leave a dead token or an "issued" audit row behind.
      ::System::NetbootService.preflight!
      resolved_image_base = resolve_image_base(image_base)

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
        image_base: resolved_image_base,
        ca_pem_url: ca_pem_url
      )

      # Observability: surfaces "boot script issued" so a stuck provision is
      # traceable through the pipeline. Best-effort — never block boot rendering.
      ::System::Fleet::EventBroadcaster.emit!(
        account: instance.account,
        kind: "system.bootstrap_issued",
        severity: :low,
        source: "bootstrap_service",
        payload: { purpose: purpose, token_id: token.id },
        node_id: instance.node_id,
        node_instance_id: instance.id
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

    # One source of truth with NetbootService: the configured enrolment platform
    # URL. No placeholder fallback; an unset URL refuses the render.
    def platform_url
      url = ::System::PhysicalEnrollmentService.platform_url.to_s.chomp("/")
      raise ::System::NetbootService::NetbootError, "platform_url required: configure the platform URL for PXE enrolment" if url.blank?

      url
    end

    # Optional override of where the agent fetches the CA PEM. Default (nil) is
    # the platform's public netboot/ca.pem route; the agent trusts the bytes only
    # if they match the cmdline ca_fingerprint pin, whatever the transport.
    def ca_pem_url
      ENV["POWERNODE_CA_PEM_URL"].presence
    end
  end
end
