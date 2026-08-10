# frozen_string_literal: true

module System
  # Best-effort, guarded revocation of an instance's dev-cell deploy key —
  # deletes the read-write Gitea deploy key and drops its Vault private key.
  # Shared by the two termination-shaped lifecycle paths (IMP-73eab188c4bd):
  # ProvisioningService#finalize_termination! and InstancePoolService's
  # reuse-without-reset release. Vault-backed key cleanup deserves ONE revoke
  # contract, not per-service copies drifting apart.
  #
  # A revoke failure must never block the caller's lifecycle step: failures
  # are swallowed and logged under the including service's own tag. No-op
  # when the DevCellDeployKey model isn't loaded or the instance never
  # bootstrapped a dev-cell key (revoke_for! no-ops internally).
  module DevCellDeployKeyRevocation
    private

    def revoke_dev_cell_deploy_key!(instance)
      return unless defined?(::System::DevCellDeployKey)

      ::System::DevCellDeployKey.revoke_for!(instance)
    rescue StandardError => e
      Rails.logger.warn(
        "[#{self.class.name.demodulize}] dev-cell deploy-key revoke failed " \
        "(instance=#{instance&.id}): #{e.class}: #{e.message}"
      )
    end
  end
end
