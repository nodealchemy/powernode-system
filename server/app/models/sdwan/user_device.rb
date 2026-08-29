# frozen_string_literal: true

# A single WireGuard client config issued to a user. The public key is
# column-stored (not secret); the private key is Vault-first via the
# VaultCredential concern at type "wireguard_user_key". Address is
# deterministically derived from device.id so operators can reverse-resolve
# from a packet capture without DB joins.
#
# Lifecycle:
#   created → pending download (last_downloaded_at: nil)
#           → downloaded (last_downloaded_at: <ts>)  [bootstrap URL is now 410]
#           → revoked    (revoked_at: <ts>)          [compiler drops from hub view]
#
# Slice 4 of the SDWAN plan.
module Sdwan
  class UserDevice < ApplicationRecord
    self.table_name = "system_sdwan_user_devices"

    include VaultCredential

    self.vault_credential_type = "wireguard_user_key"

    belongs_to :access_grant, class_name: "Sdwan::AccessGrant", foreign_key: :sdwan_access_grant_id

    delegate :network,    to: :access_grant
    delegate :account,    to: :access_grant
    delegate :account_id, to: :access_grant
    delegate :user,       to: :access_grant

    validates :label, presence: true, length: { maximum: 64 },
                      uniqueness: { scope: :sdwan_access_grant_id }
    validates :public_key, presence: true, uniqueness: true,
                           length: { is: 44 },
                           format: { with: /\A[A-Za-z0-9+\/]{43}=\z/, message: "must be a base64-encoded 32-byte key" }
    validates :assigned_address, presence: true, uniqueness: true

    before_validation :allocate_host_address, on: :create

    scope :active,    -> { where(revoked_at: nil) }
    scope :revoked,   -> { where.not(revoked_at: nil) }
    scope :downloaded, -> { where.not(last_downloaded_at: nil) }
    scope :pending_download, -> { where(last_downloaded_at: nil, revoked_at: nil) }

    def revoked?
      revoked_at.present?
    end

    def downloadable?
      !revoked? && last_downloaded_at.nil? && access_grant.active?
    end

    # Retrievability for the AUTHENTICATED OWNER path
    # (Api::V1::System::Sdwan::MyDevicesController#show), deliberately WITHOUT
    # the `last_downloaded_at.nil?` clause that `downloadable?` carries.
    #
    # That clause is the ANONYMOUS BOOTSTRAP TOKEN's security property, not the
    # device's. The bootstrap URL is a bearer credential with no identity behind
    # it: anyone who obtains the link — a forwarded Slack message, a proxy log, a
    # shoulder-surfed screen — can fetch the private key, so consumption has to
    # be one-shot. None of that holds for a request the platform has
    # authenticated as the grant's own user. There is no link to replay; the
    # requester already holds the key they are asking for, so a second fetch
    # discloses nothing a first fetch did not.
    #
    # Carrying single-use across to this path would be actively harmful. It is
    # the ONLY delivery route for a device issued with mint_bootstrap_token:
    # false (the agent arm, increment 4), so one fumbled copy/paste, one closed
    # tab, or one lost laptop would strand the device permanently and force an
    # operator round-trip to re-issue — for a user who is already proven to be
    # the rightful recipient. The single-use trade (replay risk vs. usability)
    # only pays when the credential is a URL; here it buys nothing.
    #
    # The two clauses that ARE about the device — revocation and grant status —
    # are kept verbatim. Retrieval still stops the moment access is cut.
    #
    # `last_downloaded_at` keeps being stamped on every owner fetch (see the
    # controller): it stays the "when was the config the user holds rendered"
    # clock that the staleness sensor's three-state oracle and the revoked-device
    # reaper read, and re-fetching only makes that clock MORE accurate. Deciding
    # NOT to add a separate download counter is deliberate — that would be a
    # schema change whose only consumer would be an audit view nothing has asked
    # for, and the sensor's oracle is defined over this column alone.
    #
    # ONE-WAY INTERACTION WITH THE ANONYMOUS LINK, AND IT IS THE RIGHT WAY ROUND.
    # Because `downloadable?` still requires `last_downloaded_at.nil?`, an owner
    # who self-serves a device that ALSO has a live bootstrap URL turns that URL
    # 410 Gone. That is not a broken link — it is single-use working: the config
    # was delivered, to the rightful recipient, and a bearer URL that outlives
    # its delivery is the thing single-use exists to prevent. The reverse does
    # NOT hold: consuming the bootstrap URL leaves owner retrieval intact, which
    # is the whole point of dropping the clause here. No link is invalidated by
    # anything a NON-owner can do — a refused request never reaches
    # mark_downloaded! (asserted in my_device_config_spec.rb).
    def owner_retrievable?
      !revoked? && access_grant.active?
    end

    def revoke!(reason: nil)
      return if revoked?

      update!(revoked_at: Time.current, revocation_reason: reason.to_s.presence)
    end

    # Marks the bootstrap URL as consumed. Single-use semantics: the
    # second fetch returns 410 Gone. Operator-driven re-issuance creates
    # a new UserDevice (with a fresh keypair) rather than re-arming the
    # download — so credential history is auditable.
    def mark_downloaded!
      update_columns(last_downloaded_at: Time.current, updated_at: Time.current)
    end

    # Returns the X25519 private key bytes (base64), or nil if revoked /
    # no Vault entry. Read once at bootstrap time then never again — the
    # config is rendered, the value is dropped from process memory.
    def private_key_b64
      return nil if revoked?

      data = vault_credentials
      data.is_a?(Hash) ? (data[:private_key] || data["private_key"]) : nil
    end

    private

    def allocate_host_address
      return if assigned_address.present?
      return if sdwan_access_grant_id.blank?

      self.id ||= UUID7.generate
      net = network
      return unless net

      self.assigned_address = ::Sdwan::PrefixAllocator.allocate_peer_address!(network: net, peer_id: id)
    end
  end
end
