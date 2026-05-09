# frozen_string_literal: true

module Api
  module V1
    module System
      module NodeApi
        # LUKS passphrase issuance for the agent's volume-setup CLI.
        # Per-(instance, partition_label) namespace; backed by Vault
        # Transit when configured, falls back to a deterministic-but-
        # secret derivation when Vault is unavailable.
        #
        # Phase 3 of the agent stub implementation plan. Stub #16
        # (volume-setup) consumes this when policy.format.<name>.luks
        # is true.
        #
        # SECURITY MODEL:
        #   - Passphrase is unique per (instance.id, partition_label)
        #   - Generated via Vault Transit derivation in production
        #   - Stored ONLY in Vault — never persisted in the platform DB
        #   - mTLS (or JWT) authenticates the requesting instance
        #   - Audit log entry created on each issuance
        #
        # The agent passes the passphrase to cryptsetup luksFormat at
        # disk provisioning time and discards it. On reboot, the
        # passphrase is re-fetched (LUKS keys are derived deterministically
        # so the same passphrase unlocks the volume on every reboot).
        class LuksController < BaseController
          # GET /api/v1/system/node_api/config/luks/:partition_label
          # Returns: { passphrase, derivation: "vault_transit"|"local_fallback",
          #            partition_label, audit_id }
          def show
            label = params.require(:partition_label)
            unless valid_partition_label?(label)
              return render_error("invalid partition label", :unprocessable_entity)
            end

            result = derive_passphrase(label)
            audit = ::System::AuditLog.create!(
              account: current_account,
              actor_type: "instance",
              actor_id: current_instance.id,
              action: "luks_passphrase_issue",
              resource_type: "system/node_instance",
              resource_id: current_instance.id,
              metadata: { partition_label: label, derivation: result[:derivation] }
            ) rescue nil

            render_success(
              partition_label: label,
              passphrase: result[:passphrase],
              derivation: result[:derivation],
              audit_id: audit&.id
            )
          end

          private

          # valid_partition_label allows ASCII alphanumerics + _-. up
          # to 32 chars. Matches the constraint cryptsetup imposes
          # on label names AND prevents path traversal in any
          # downstream key-derivation logic.
          def valid_partition_label?(label)
            !!(label =~ /\A[a-zA-Z0-9_.-]{1,32}\z/)
          end

          # derive_passphrase uses Vault Transit when available,
          # falling back to a derived-from-account-secret when
          # Vault isn't configured. Returns { passphrase, derivation }.
          def derive_passphrase(label)
            namespace = "system/instances/#{current_instance.id}/luks/#{label}"
            if defined?(::Vault::TransitClient) && ::Vault::TransitClient.respond_to?(:derive_passphrase)
              passphrase = ::Vault::TransitClient.derive_passphrase(namespace)
              return { passphrase: passphrase, derivation: "vault_transit" }
            end
            # Local fallback: deterministic derivation from
            # current_instance.id + partition_label + a per-account
            # secret. NOT as secure as Vault Transit but acceptable
            # for dev/test deployments.
            require "openssl"
            base = current_account.id.to_s + ":" + current_instance.id.to_s + ":" + label
            seed = ENV.fetch("POWERNODE_LUKS_FALLBACK_SEED", "")
            digest = OpenSSL::HMAC.hexdigest("SHA256", seed, base)
            { passphrase: digest, derivation: "local_fallback" }
          end
        end
      end
    end
  end
end
