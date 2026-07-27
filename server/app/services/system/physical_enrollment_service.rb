# frozen_string_literal: true

module System
  # Drives the claim-code physical-device enrollment flow.
  #
  # Three entry points covering the full state diagram:
  #
  #   1. record_discovery!(payload)   — called from POST /node_api/claim
  #      every time a device polls. Upsert by (account_id, discovered_mac).
  #      First poll creates a row; subsequent polls refresh last_seen_at
  #      and expires_at without minting new claim codes.
  #
  #   2. confirm_claim!(unclaimed:, node_instance:, by_user:)
  #      — called from operator UI. Atomic: bind the device to the
  #      target instance, update both records, emit a FleetEvent. Does
  #      NOT issue the bootstrap token yet — the token is minted on the
  #      next /claim poll so its plaintext is never persisted.
  #
  #   3. poll_status(unclaimed)       — called by /node_api/claim on every
  #      poll AFTER record_discovery! has updated the row. Returns either
  #      {status: "pending"} (operator hasn't confirmed yet) or
  #      {status: "claimed", bootstrap_token: <plaintext>, instance_uuid: ...}
  #      (operator has confirmed; we issue + return the single-use token).
  #
  # Reference: docs/plans/wondrous-yawning-anchor.md §5 + §11.
  class PhysicalEnrollmentService
    # Account scoping during the discovery upsert. We don't have a per-
    # device authentication mechanism (the whole point of claim-code is
    # that an unprovisioned device has no credentials) so all discoveries
    # land in the platform's "default" account. Real multi-tenant
    # deployments would need a per-network DHCP-option-derived account,
    # which is deferred.
    def self.default_account
      ::Account.find_by(name: "Powernode") || ::Account.first
    end

    # ---- 1. Discovery (anonymous /claim POST) ------------------------------

    DiscoveryResult = Struct.new(:unclaimed, :created, keyword_init: true)

    # @param mac [String] required — primary key for upsert
    # @param dmi_uuid [String] optional — secondary identity hint
    # @param hostname [String] optional
    # @param agent_version [String] optional
    # @param architecture [String] optional ("arm64" / "amd64")
    # @param platform_hint [String] optional ("rpi4" / "generic-uefi" / etc.)
    # @param account [Account] defaults to default_account
    # @param ttl [ActiveSupport::Duration] expires_at = now + ttl
    # @return [DiscoveryResult]
    def self.record_discovery!(mac:, dmi_uuid: nil, hostname: nil,
                               agent_version: nil, architecture: nil,
                               platform_hint: nil, account: nil,
                               ttl: ::System::UnclaimedDevice::DEFAULT_TTL)
      raise ArgumentError, "mac is required" if mac.blank?

      account ||= default_account
      raise ArgumentError, "no account available for discovery" unless account

      now = Time.current
      created = false

      device = ::System::UnclaimedDevice
                 .where(account: account, discovered_mac: mac)
                 .where("expires_at > ?", now)
                 .first

      if device.nil?
        device = ::System::UnclaimedDevice.create!(
          account:             account,
          claim_code:          ::System::UnclaimedDevice.generate_claim_code,
          discovered_mac:      mac,
          discovered_dmi_uuid: dmi_uuid,
          discovered_hostname: hostname,
          agent_version:       agent_version,
          architecture:        architecture,
          platform_hint:       platform_hint,
          first_seen_at:       now,
          last_seen_at:        now,
          expires_at:          now + ttl
        )
        created = true
        emit_discovered_event(device)
      else
        device.update!(
          last_seen_at:        now,
          expires_at:          now + ttl,
          discovered_dmi_uuid: device.discovered_dmi_uuid.presence || dmi_uuid,
          discovered_hostname: device.discovered_hostname.presence || hostname,
          agent_version:       agent_version || device.agent_version,
          architecture:        architecture || device.architecture,
          platform_hint:       platform_hint || device.platform_hint
        )
      end

      DiscoveryResult.new(unclaimed: device, created: created)
    end

    # ---- 2. Operator confirms (operator UI POST :claim) ---------------------

    ConfirmResult = Struct.new(:ok?, :unclaimed, :node_instance, :error,
                               keyword_init: true)

    # @param unclaimed [System::UnclaimedDevice]
    # @param node_instance [System::NodeInstance]
    # @param by_user [User] for audit log
    # @return [ConfirmResult]
    def self.confirm_claim!(unclaimed:, node_instance:, by_user: nil)
      return ConfirmResult.new(ok?: false, error: "unclaimed device required") unless unclaimed
      return ConfirmResult.new(ok?: false, error: "node_instance required")    unless node_instance
      return ConfirmResult.new(ok?: false, error: "instance already running")  if node_instance.respond_to?(:running?) && node_instance.running?
      return ConfirmResult.new(ok?: false, error: "device already claimed")    if unclaimed.claimed?

      ::ActiveRecord::Base.transaction do
        unclaimed.update!(
          claimed_at:                 Time.current,
          claimed_node_instance_id:   node_instance.id
        )
        node_instance.update!(
          claim_code:           unclaimed.claim_code,
          claimed_at:           Time.current,
          discovered_mac:       unclaimed.discovered_mac,
          discovered_dmi_uuid:  unclaimed.discovered_dmi_uuid,
          discovered_hostname:  unclaimed.discovered_hostname,
          discovered_at:        unclaimed.first_seen_at
        )
      end
      emit_claimed_event(unclaimed: unclaimed, node_instance: node_instance, by_user: by_user)

      ConfirmResult.new(ok?: true, unclaimed: unclaimed, node_instance: node_instance)
    rescue ::ActiveRecord::RecordInvalid => e
      ConfirmResult.new(ok?: false, error: e.message)
    end

    # ---- 2b. Auto-confirm by instance ID (claim-by-ID, no operator) ---------

    # Claim-by-ID path for the generic-image fleet workflow: a device flashed
    # from a generic image carries a per-instance identity.cfg (ID=<uuid>) and
    # sends instance_id in its /claim poll. If that ID matches a *claimable*
    # NodeInstance (physical, pending, not yet bound to a device), bind it
    # automatically via confirm_claim! — no operator confirmation — so the same
    # poll mints + returns the bootstrap token. Returns nil (no-op) when the ID
    # is blank/unknown, the instance isn't claimable, or the device is already
    # claimed, leaving the caller on the normal pending/claim-code path so a
    # wrong ID can't strand the device or hijack a live instance.
    def self.auto_confirm_by_instance_id!(unclaimed:, instance_id:)
      return nil if unclaimed.nil? || unclaimed.claimed? || instance_id.blank?

      instance = ::System::NodeInstance.claimable.find_by(id: instance_id)
      return nil unless instance

      confirm_claim!(unclaimed: unclaimed, node_instance: instance, by_user: nil)
    end

    # ---- 3. Poll status (every /claim POST after discovery) -----------------

    PollResponse = Struct.new(:status, :claim_code, :poll_after_seconds,
                              :bootstrap_token, :instance_uuid, :ca_pem_url,
                              :platform_url, keyword_init: true)

    # @param unclaimed [System::UnclaimedDevice]
    # @return [PollResponse]
    def self.poll_status(unclaimed)
      return PollResponse.new(status: "expired", poll_after_seconds: 0) unless unclaimed
      return PollResponse.new(status: "expired", poll_after_seconds: 0) if unclaimed.expires_at.past?

      unless unclaimed.claimed?
        return PollResponse.new(
          status:             "pending",
          claim_code:         unclaimed.claim_code,
          poll_after_seconds: 30
        )
      end

      # Operator confirmed: mint a single-use bootstrap token and return
      # plaintext. Plaintext is never persisted; subsequent polls cannot
      # retrieve the same token (single-use enforcement at /enroll).
      instance = unclaimed.claimed_node_instance
      return PollResponse.new(status: "expired") unless instance

      _token, plaintext = ::System::BootstrapToken.issue!(
        node:             instance.node,
        node_instance:    instance,
        intended_subject: instance.id,
        ttl:              1.hour,
        purpose:          "physical_claim"
      )

      PollResponse.new(
        status:          "claimed",
        bootstrap_token: plaintext,
        instance_uuid:   instance.id,
        platform_url:    platform_url,
        ca_pem_url:      ca_pem_url
      )
    end

    # ---- Internals ---------------------------------------------------------

    def self.emit_discovered_event(device)
      return unless defined?(::System::Fleet::EventBroadcaster)

      ::System::Fleet::EventBroadcaster.emit!(
        account:  device.account,
        kind:     "system.physical_device_discovered",
        severity: :low,
        source:   "claim_endpoint",
        payload: {
          unclaimed_device_id: device.id,
          mac:                 device.discovered_mac,
          dmi_uuid:            device.discovered_dmi_uuid,
          hostname:            device.discovered_hostname,
          architecture:        device.architecture,
          platform_hint:       device.platform_hint,
          claim_code:          device.claim_code
        }
      )
    rescue StandardError => e
      Rails.logger.warn "[PhysicalEnrollmentService] discover event emit failed: #{e.class}: #{e.message}"
    end

    def self.emit_claimed_event(unclaimed:, node_instance:, by_user:)
      return unless defined?(::System::Fleet::EventBroadcaster)

      ::System::Fleet::EventBroadcaster.emit!(
        account:                node_instance.account,
        kind:                   "system.physical_device_claimed",
        severity:               :low,
        source:                 "operator_ui",
        node_module_id:         nil,
        payload: {
          unclaimed_device_id: unclaimed.id,
          node_instance_id:    node_instance.id,
          node_instance_name:  node_instance.name,
          mac:                 unclaimed.discovered_mac,
          by_user_id:          by_user&.id
        }
      )
    rescue StandardError => e
      Rails.logger.warn "[PhysicalEnrollmentService] claim event emit failed: #{e.class}: #{e.message}"
    end

    # Where a claim-by-ID device should call home. Returns nil when nothing is
    # configured — deliberately, because the caller emits this verbatim into an
    # identity.cfg that gets flashed onto physical media.
    #
    # This used to fall back to "https://platform.local" in production and
    # "http://localhost:3000" otherwise. Both are fabrications, and a fabricated
    # value is far worse here than no value: it produces a boot config that looks
    # completely valid, passes every glance, and then fails to resolve on a device
    # that has already been flashed and shipped. The operator finds out at the
    # site, not at the desk. A missing value can be surfaced as a placeholder the
    # reader must fill in; an invented one cannot be distinguished from a real one.
    #
    # Resolution order reuses the SAME SiteSetting the VM/cicustom enrollment path
    # reads (Providers::Proxmox::EnrollmentSeed#resolve_platform_url) rather than
    # introducing a second key. Both paths answer one question — "where do devices
    # enroll?" — and two sources of truth for that is how a fleet ends up split
    # across planes. The key name is historical (it predates the physical path);
    # its meaning is the platform's enrollment URL.
    PLATFORM_URL_SETTING = "system.ci_builder.enroll_platform_url"
    # Presence means devices cannot rely on public roots and MUST carry this chain.
    ENROLL_CA_SETTING    = "system.ci_builder.enroll_ca_pem"

    def self.platform_url
      ::SiteSetting.get(PLATFORM_URL_SETTING).presence || ENV["POWERNODE_PLATFORM_URL"].presence
    rescue StandardError => e
      Rails.logger.warn "[PhysicalEnrollmentService] platform_url lookup failed: #{e.class}: #{e.message}"
      ENV["POWERNODE_PLATFORM_URL"].presence
    end

    # True when this platform serves a chain the stock image does not already
    # trust, so a claim-by-ID device needs the CA on its BOOT partition. ops-hub
    # is self-signed (verified 2026-07-26: subject == issuer == CN=ops-hub.ipnode.us),
    # which is exactly the case that silently fails TLS if the CA is left out.
    def self.private_ca?
      ::SiteSetting.get(ENROLL_CA_SETTING).present?
    rescue StandardError
      false
    end

    def self.ca_pem_url
      ENV["POWERNODE_CA_PEM_URL"]
    end
  end
end
