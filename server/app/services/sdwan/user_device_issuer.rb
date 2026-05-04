# frozen_string_literal: true

# Issues a fresh Sdwan::UserDevice + a one-shot signed bootstrap token.
# The token is the operator's hand-off vehicle: they generate the device,
# get back a 15-minute-expiring token URL, send it to the user via any
# channel, and the user fetches the WG config exactly once.
#
# Single-use is enforced at the model layer (UserDevice#mark_downloaded!).
# Token validity is enforced cryptographically via Rails' message_verifier
# — the token carries the device_id and an expiry; the platform never has
# to consult an "unused tokens" table.
#
# Slice 4 of the SDWAN plan.
require "active_support/message_verifier"

module Sdwan
  class UserDeviceIssuer
    class GrantError < StandardError; end
    class BootstrapTokenError < StandardError; end

    BOOTSTRAP_TTL     = 15.minutes
    BOOTSTRAP_PURPOSE = :sdwan_user_device_bootstrap

    # Returns { device: UserDevice, bootstrap_token: String, expires_at: ISO8601 }.
    # The bootstrap_token is what the operator hands to the user, embedded
    # in the URL. The device is persisted with public_key and assigned_address.
    def self.issue!(grant:, label:)
      raise GrantError, "grant is not active" unless grant.active?

      keypair = ::Sdwan::KeyDistributor.generate_keypair

      device = nil
      ::Sdwan::UserDevice.transaction do
        device = ::Sdwan::UserDevice.create!(
          access_grant: grant,
          label: label,
          public_key: keypair[:public_key_b64]
        )
        device.store_in_vault(
          public_key: keypair[:public_key_b64],
          private_key: keypair[:private_key_b64],
          algorithm: "X25519",
          generated_at: Time.current.iso8601
        )
        device.reload
      end

      token = bootstrap_token_for(device)
      {
        device: device,
        bootstrap_token: token,
        expires_at: BOOTSTRAP_TTL.from_now.utc.iso8601
      }
    end

    # Generates the signed token. message_verifier guarantees integrity +
    # expiry without a database round-trip; the only stateful gate is
    # UserDevice#last_downloaded_at, checked on consumption.
    def self.bootstrap_token_for(device)
      Rails.application.message_verifier(BOOTSTRAP_PURPOSE).generate(
        { device_id: device.id },
        expires_in: BOOTSTRAP_TTL
      )
    end

    # Returns { device_id: ... } on success, raises BootstrapTokenError on
    # invalid/expired/tampered token. Callers MUST then check
    # device.downloadable? before serving the config — token validity is
    # one of two gates; single-use enforcement is the other.
    def self.verify_bootstrap_token!(token)
      payload = Rails.application.message_verifier(BOOTSTRAP_PURPOSE).verify(token)
      # Rails 8's default verifier serializes via JSON, which converts
      # symbol keys to strings on round-trip. Accept both shapes.
      device_id = payload.is_a?(Hash) ? (payload[:device_id] || payload["device_id"]) : nil
      raise BootstrapTokenError, "missing device_id" unless device_id

      { device_id: device_id }
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      raise BootstrapTokenError, "invalid or expired bootstrap token"
    end
  end
end
