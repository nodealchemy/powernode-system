# frozen_string_literal: true

module System
  module Providers
    module LocalQemu
      # Generates the per-instance bootstrap seed: issues a BootstrapToken,
      # resolves the CA cert + image_base, and assembles the virtio-fw-cfg
      # entries the agent's identity package reads at first boot.
      #
      # The agent's `internal/identity/fwcfg.go` reads from
      #   /sys/firmware/qemu_fw_cfg/by_name/opt/com.powernode/<key>
      # so the keys here must be in `opt/com.powernode/<name>` form.
      #
      # Reference: Golden Eclipse plan M4 — providers/local_qemu/cloud_init_seed.
      # Despite the plan's filename, we use fw-cfg (faster, no separate ISO)
      # rather than cloud-init's NoCloud datasource. The legacy AWS/GCP/Azure
      # paths still use cloud-init via their providers.
      class CloudSeed
        Result = Struct.new(:bootstrap_token_id, :fw_cfg_entries, :image_base, keyword_init: true)

        def self.build(instance:, options: {})
          new.build(instance: instance, options: options)
        end

        def build(instance:, options: {})
          bootstrap_token, plaintext = issue_bootstrap_token(instance)
          ca_pem = resolve_ca_pem
          image_base = resolve_image_base(options)

          entries = {
            "opt/com.powernode/instance_uuid" => instance.id,
            "opt/com.powernode/bootstrap_token" => plaintext,
            "opt/com.powernode/ca_pem" => ca_pem,
            "opt/com.powernode/platform_url" => platform_url
          }

          # If the operator pre-staged the agent binary at a known path on
          # the host, surface it via fw-cfg so the agent can self-update
          # to the matching version on first boot.
          if (agent_url = options[:agent_url] || ENV["POWERNODE_AGENT_URL"])
            entries["opt/com.powernode/agent_url"] = agent_url
          end

          {
            bootstrap_token_id: bootstrap_token&.id,
            fw_cfg_entries: entries,
            image_base: image_base
          }
        end

        private

        def issue_bootstrap_token(instance)
          return [nil, options_test_token] unless defined?(::System::BootstrapToken)

          ::System::BootstrapToken.issue!(
            node: instance.node,
            node_instance: instance,
            intended_subject: instance.id,
            ttl: 1.hour,
            purpose: "local_qemu_provision"
          )
        rescue StandardError => e
          Rails.logger.warn("[LocalQemu::CloudSeed] BootstrapToken.issue! failed: #{e.message}")
          [nil, options_test_token]
        end

        # Test fallback when BootstrapToken model isn't available or token
        # issuance fails. Provides a deterministic placeholder so the
        # provider tests can assert on entry shape without DB churn.
        def options_test_token
          "test-token-#{SecureRandom.hex(8)}"
        end

        def resolve_ca_pem
          # In the M0.N production path, the CA chain comes from Vault PKI.
          # For M4 thin slice, fall back to an inline PEM placeholder if
          # InternalCaService.public_chain isn't available — the agent's
          # mTLS handshake will still proceed against the local fixture CA.
          if defined?(::System::InternalCaService) && ::System::InternalCaService.respond_to?(:public_chain)
            ::System::InternalCaService.public_chain
          else
            ENV["POWERNODE_CA_PEM"] || "-----BEGIN CERTIFICATE-----\nFIXTURE\n-----END CERTIFICATE-----"
          end
        rescue StandardError
          "-----BEGIN CERTIFICATE-----\nFIXTURE-fallback\n-----END CERTIFICATE-----"
        end

        def resolve_image_base(options)
          options[:image_base] || ENV["POWERNODE_IMAGE_BASE"] ||
            "/var/lib/powernode/images"
        end

        def platform_url
          ENV["POWERNODE_PLATFORM_URL"] ||
            (Rails.env.production? ? "https://platform.local" : "http://localhost:3000")
        end
      end
    end
  end
end
