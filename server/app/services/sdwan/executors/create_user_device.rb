# frozen_string_literal: true

module Sdwan
  module Executors
    # Executor for `sdwan.user_device_create` — mints one VPN client config
    # under an access grant: a fresh WireGuard keypair (private half stored in
    # Vault), an allocated overlay address, and a one-shot bootstrap token that
    # serves the full client config exactly once.
    #
    # IMP-051f3811ac60: the category was seeded and registered from the start
    # but this executor had no dispatcher, and its never-called body did a bare
    # `user_devices.create!` — no keypair, no Vault write, no token — a device
    # row that satisfies no validation and could never connect. The write is
    # therefore DELEGATED to Sdwan::UserDeviceIssuer, the same seam both
    # operator surfaces (UserDevicesController#create,
    # Ai::Tools::SdwanTool#issue_user_device) called inline before they gated.
    #
    # TOKEN CONTRACT: bootstrap_token in the returned data is secret material
    # revealed exactly once, the same shape as ProposeFederationPeer's
    # acceptance token. Ai::DeferredOperation#execute_now! hands the raw return
    # to the inline caller (and to the reveal-once slot on the approval path)
    # while persisting only Ai::SensitiveParams.filter(...) — whose "token"
    # pattern masks it — so the operation row never holds a durable second
    # copy. Do not rename the key away from *token*.
    class CreateUserDevice < ::System::Executors::Base
      # Single source of this action's autonomy category (IMP-249e01a804e5) —
      # read by both gate sites above and pinned to the seeded policy row +
      # engine registration by action_category_coherence_spec.rb.
      ACTION_CATEGORY = "sdwan.user_device_create"

      protected

      def perform
        grant = resolve_scoped(::Sdwan::AccessGrant, params[:grant_id])
        # UserDeviceIssuer re-raises GrantError on a non-active grant — the
        # surfaces refuse that pre-gate, but the grant can change inside the
        # approval window, and the executor is the enforcement.
        result = ::Sdwan::UserDeviceIssuer.issue!(grant: grant, label: params[:label])

        {
          device_id: result[:device].id,
          grant_id: grant.id,
          bootstrap_token: result[:bootstrap_token],
          expires_at: result[:expires_at]
        }
      end

      def summarize
        grant = scoped_label_record(::Sdwan::AccessGrant, params[:grant_id])
        label = params[:label].presence
        owner = grant&.user&.email.presence

        base = label ? "Issue SDWAN VPN device '#{label}'" : "Issue SDWAN VPN device config"
        owner ? "#{base} for #{owner}" : base
      end

      def impact
        "Mints a WireGuard keypair (Vault-stored) and a one-shot bootstrap token granting VPN access"
      end
    end
  end
end
