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

      # CONTROL FLAGS, not columns — they steer token minting and never reach a
      # write payload or an approval card. Same shape and same reason as
      # ProposeFederationPeer::CONTROL_FLAG_KEYS, whose `generate_token` this
      # mirrors (Ai::Tools::SdwanTool#propose_federation_peer cites that pair
      # where it refuses to deliver an acceptance token over MCP).
      #
      # `mint_bootstrap_token: false` issues the device and mints NO bootstrap
      # token — the device is fully created (row, Vault private half, allocated
      # address) and `bootstrap_token`/`expires_at` come back nil. It is for a
      # surface that must not hand back a bootstrap URL, since that URL is the
      # sole auth for an anonymous endpoint serving a WireGuard private key.
      # Such a surface OWES the recipient another route to the config; a device
      # issued with no token and no alternative path is stranded.
      #
      # DEFAULT IS MINT, as in ProposeFederationPeer. Every caller today omits
      # the flag and is unaffected.
      #
      # This executor's params are FLAT (grant_id, label) and it mass-assigns
      # nothing, so there is no create! payload to subtract the flag from. The
      # exclusion that still bites is the CARD: System::Executors::Base builds
      # "Sets fields: …" from `attrs.keys & named_attribute_keys`, so a surface
      # that ever routed this flag under params[:attributes] would have an
      # approval card announce a field no row has (IMP-35bc8eda71ad). The
      # override below is that guard, and it shares this constant with the read
      # in #perform so the two cannot drift.
      CONTROL_FLAG_KEYS = %i[mint_bootstrap_token].freeze

      protected

      def perform
        grant = resolve_scoped(::Sdwan::AccessGrant, params[:grant_id])
        mint_bootstrap_token = suppression_flag_set?(:mint_bootstrap_token) ? false : true

        # UserDeviceIssuer re-raises GrantError on a non-active grant — the
        # surfaces refuse that pre-gate, but the grant can change inside the
        # approval window, and the executor is the enforcement.
        result = ::Sdwan::UserDeviceIssuer.issue!(
          grant: grant,
          label: params[:label],
          mint_bootstrap_token: mint_bootstrap_token
        )

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

      # The card names what #perform WRITES (IMP-35bc8eda71ad). The control
      # flags steer minting and never reach a column, so they are subtracted
      # here as they are in ProposeFederationPeer.
      def named_attribute_keys = attrs.keys - CONTROL_FLAG_KEYS

      # Reads a declared control flag. Going through CONTROL_FLAG_KEYS rather
      # than params[...] directly is what keeps the constant and the read from
      # drifting: a flag read but never declared raises here instead of quietly
      # steering behaviour the approval card still announces as a field.
      #
      # Accepted from EITHER shape. The two gating surfaces build flat executor
      # params, but the base class's card machinery only ever looks at
      # params[:attributes] — and a suppression flag that is silently ignored
      # fails in the dangerous direction: the surface believes it refused the
      # token and the executor mints one anyway. Honour both.
      #
      # The :attributes read is shape-guarded for the reason
      # System::Executors::Base#changed_field_impact states — ActionController
      # ::Parameters answers #keys and then RAISES inside #attrs — except that
      # here a raise would fail the EXECUTION, not merely blank a card.
      def control_flag(key)
        raise ArgumentError, "#{key} is not a declared control flag" unless CONTROL_FLAG_KEYS.include?(key)
        return params[key] if params.key?(key)

        params[:attributes].is_a?(Hash) ? attrs[key] : nil
      end

      # True only when the flag is present AND falsy. Everything else — absent,
      # nil, true, an empty string — mints, which is the default this increment
      # must not disturb.
      #
      # ProposeFederationPeer writes this as a bare `!= false` and this
      # deliberately does not, because the two flags fail in OPPOSITE
      # directions. There, an unrecognised value mints a token an operator then
      # copies out of band — noisy but safe. Here, suppression is the safety
      # property: a surface that passes the string "false" (a form or query
      # param, which increment 3's frontend makes reachable) would satisfy
      # `!= false`, mint a bootstrap URL the surface believes it refused, and
      # re-open the anonymous-endpoint disclosure this flag exists to close.
      # Coercing FIRST makes the unrecognised case fail toward suppression.
      #
      # ActiveModel::Type::Boolean is the same coercion
      # Ai::Tools::SdwanTool#propose_federation_peer already applies to
      # generate_token at its refusal check, so this is the in-repo reading of
      # a control flag arriving from an untrusted shape, not a new convention.
      def suppression_flag_set?(key)
        raw = control_flag(key)
        !raw.nil? && ::ActiveModel::Type::Boolean.new.cast(raw) == false
      end
    end
  end
end
