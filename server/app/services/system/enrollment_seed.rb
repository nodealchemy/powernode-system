# frozen_string_literal: true

module System
  # The ONE issuer of platform-injected enrolment keys (design D12, operator
  # 2026-10-20): when the platform itself provisions a VM it mints a single-use
  # BootstrapToken, bound to the NodeInstance, valid for 1 hour, and injects it
  # with no human step. Every mint goes through BootstrapToken.issue!, which
  # writes exactly one audit row inside the mint transaction and fails closed.
  #
  #   .issue_token      -> [BootstrapToken, plaintext]   (legacy-format channels)
  #   .render_user_data -> Result                        (provisioning document v1)
  #
  # The key is RE-MINTED on every VM start (each call mints a fresh one); the
  # previous key was consumed by the previous boot's enrolment or has expired.
  #
  # Fail-closed: a document is rendered inside the same transaction as the mint,
  # so a missing/invalid CA (System::ProvisioningDocument::RenderError) rolls the
  # token and its audit row back and raises SeedError. A pin-less document is
  # never produced. The plaintext key is never logged and never put in an error
  # message; callers own the returned string.
  class EnrollmentSeed
    TTL = 1.hour
    CLOUD_PURPOSE = "cloud_seed"
    JSON_PART_TYPE = "application/x-powernode-provision+json"
    BOUNDARY_PREFIX = "powernode-seed"

    Result = Struct.new(:user_data, :bootstrap_token_id, :expires_at, keyword_init: true)

    class SeedError < StandardError; end

    class << self
      # Single mint path for every channel (v1 JSON, fw-cfg, cicustom).
      def issue_token(instance:, purpose: CLOUD_PURPOSE)
        ::System::BootstrapToken.issue!(
          node: instance.node,
          node_instance: instance,
          intended_subject: instance.id,
          ttl: TTL,
          purpose: purpose
        )
      end

      # @param instance [System::NodeInstance]
      # @param extra [String, nil] operator/template init script. When present the
      #   result is a MIME multipart: part 1 is the v1 document (head), part 2 the
      #   script as text/cloud-config or text/x-shellscript. Without it the result
      #   is the bare v1 JSON (what the agent reads from cloud user-data).
      # @param server [String, nil] https platform URL override (default: configured)
      # @return [Result]
      def render_user_data(instance:, purpose: CLOUD_PURPOSE, extra: nil, server: nil, ca_pem: nil)
        result = nil
        ::System::BootstrapToken.transaction do
          token, plaintext = issue_token(instance: instance, purpose: purpose)
          document = ::System::ProvisioningDocument.render(
            instance: instance, key: plaintext, purpose: purpose,
            expires_at: token.expires_at, server: server, ca_pem: ca_pem
          )
          result = Result.new(
            user_data: compose(document, extra),
            bootstrap_token_id: token.id,
            expires_at: token.expires_at
          )
        end
        result
      rescue ::System::ProvisioningDocument::RenderError => e
        # RenderError messages never carry the key (see ProvisioningDocument).
        raise SeedError, "refusing to seed instance #{instance.id}: #{e.message}"
      end

      # The template's stored init_script (NodeTemplate#config), carried as the
      # second MIME part. nil when the node has no template or no script.
      def template_init_script(node)
        cfg = node&.node_template&.config
        return nil unless cfg.is_a?(Hash)

        script = cfg["init_script"] || cfg[:init_script]
        script.is_a?(String) && script.present? ? script : nil
      end

      # v1 document as the head, extra script as a second MIME part. cloud-init
      # ignores the unknown JSON part type and runs the script part; the agent
      # selects the JSON part (agent/internal/identity/cloud.go).
      def compose(document, extra)
        return document if extra.to_s.strip.empty?

        boundary = "#{BOUNDARY_PREFIX}-#{SecureRandom.hex(12)}"
        [
          "MIME-Version: 1.0",
          "Content-Type: multipart/mixed; boundary=\"#{boundary}\"",
          "",
          "--#{boundary}",
          "Content-Type: #{JSON_PART_TYPE}; charset=\"utf-8\"",
          "Content-Disposition: attachment; filename=\"powernode-provision.json\"",
          "",
          document,
          "--#{boundary}",
          "Content-Type: #{part_type_for(extra)}; charset=\"utf-8\"",
          "Content-Disposition: attachment; filename=\"user-script\"",
          "",
          extra.to_s.chomp,
          "--#{boundary}--",
          ""
        ].join("\n")
      end

      def part_type_for(script)
        head = script.to_s.lstrip
        return "text/cloud-config" if head.start_with?("#cloud-config")
        return "text/x-shellscript" if head.start_with?("#!")

        "text/cloud-config"
      end
    end
  end
end
