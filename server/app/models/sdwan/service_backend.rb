# frozen_string_literal: true

module Sdwan
  # One member of a published service's load-balanced backend set (APO-3c).
  #
  # Sdwan::Service's own backend_vip/backend_host + backend_port columns describe
  # a SINGLE backend and stay authoritative for a service nobody has scaled.
  # This table is the fan-out: once a service has at least one active row here,
  # Sdwan::Service#load_balanced_backends returns the set and
  # Sdwan::ServiceExposureWriter emits one Traefik server per member.
  #
  # Deliberately NOT modelled as "the first row is the legacy backend": a
  # service with zero rows renders exactly what it rendered before this table
  # existed, which is what keeps the degenerate output byte-identical. Nothing
  # backfills a row for the legacy columns, so no existing service changes shape
  # until an operator (or, once APO-4 lands, replace-instance) adds one.
  #
  # `status` is the drain switch. A "draining" member stays in the table — its
  # history and its weight survive — but leaves the emitted server list, which
  # is what a rolling replacement needs between "stop sending it new work" and
  # "the instance is gone".
  #
  # Draining EVERY member is NOT a way to take a service out of rotation: the
  # active set is then empty and #load_balanced_backends falls back to the
  # legacy single-backend columns, which after a replace-instance cycle may name
  # an address that no longer answers. That fallback is deliberate — it keeps
  # the ONE code path and never emits a `servers` list with nothing in it — but
  # it means "drain them all" reads as "send everything to the original host".
  # To stop routing, disable the service (local_enabled/public_enabled), which
  # the writer already skips.
  class ServiceBackend < ApplicationRecord
    self.table_name = "system_sdwan_service_backends"

    STATUSES = %w[active draining].freeze
    DEFAULT_WEIGHT = 1
    MIN_WEIGHT = 1
    # Matches the sdwan_service_backends_weight_range check constraint. A ceiling
    # exists because Traefik's WRR scheduler allocates per-weight turns; an
    # unbounded weight is a memory/latency footgun, not a finer ratio.
    MAX_WEIGHT = 1000

    belongs_to :account
    belongs_to :service, class_name: "::Sdwan::Service",
               foreign_key: :sdwan_service_id, inverse_of: :backends
    belongs_to :backend_vip, class_name: "::Sdwan::VirtualIp",
               foreign_key: :backend_vip_id, optional: true

    before_validation :inherit_account_from_service

    validates :backend_port, presence: true,
                             numericality: { only_integer: true, in: 1..65_535 }
    validates :weight, presence: true,
                       numericality: { only_integer: true, in: MIN_WEIGHT..MAX_WEIGHT }
    validates :status, inclusion: { in: STATUSES }
    validate :backend_present
    validate :account_matches_service
    validate :backend_unique_within_service

    # The overlay address (VIP host or static host) without scheme/port —
    # same contract as Sdwan::Service#backend_address.
    def address
      return backend_vip.cidr.to_s.split("/").first if backend_vip

      backend_host
    end

    # The upstream URL Traefik dials for this member. Mirrors
    # Sdwan::Service#backend_url (IPv6 hosts bracketed for the URL authority).
    def url(scheme:)
      "#{scheme}://#{::Sdwan::HostPort.join(address, backend_port)}"
    end

    private

    def inherit_account_from_service
      self.account_id ||= service&.account_id
    end

    def backend_present
      return if backend_vip_id.present? || backend_host.present?

      errors.add(:base, "a backend_vip or backend_host must be set")
    end

    # A backend seated under one account's service but stamped with another
    # account would leak across the tenant boundary the writer scopes by.
    def account_matches_service
      return if service.nil? || account_id.nil?
      return if account_id == service.account_id

      errors.add(:account_id, "must match the service's account")
    end

    # Two members dialling the same address:port are not two backends — they are
    # one backend counted twice, which silently doubles its share of a
    # round-robin set.
    #
    # The SAME-FORM case (two vip rows, or two host rows) is caught in the
    # database by the functional unique index
    # idx_sdwan_service_backends_unique_address on
    # (sdwan_service_id, backend_port, COALESCE(backend_vip_id::text, backend_host)),
    # which is what makes a concurrent double-insert impossible — the automated
    # producer (APO-4) is exactly the caller that would race here.
    #
    # This validation remains for the CROSS-FORM case the index cannot see: a
    # backend_vip whose resolved CIDR host equals another row's literal
    # backend_host. Those are two different index keys but one address, so only
    # Ruby (which dereferences the VIP) can tell they collide. It also turns the
    # same-form clash into a validation error instead of a RecordNotUnique.
    def backend_unique_within_service
      return if sdwan_service_id.blank?

      # includes(:backend_vip): #address dereferences the VIP, so an unloaded
      # association would issue one SELECT per sibling row on every create.
      scope = self.class.includes(:backend_vip)
                  .where(sdwan_service_id: sdwan_service_id, backend_port: backend_port)
      scope = scope.where.not(id: id) if id.present?
      return unless scope.any? { |other| other.address == address }

      errors.add(:base, "#{address}:#{backend_port} is already a backend of this service")
    end
  end
end
