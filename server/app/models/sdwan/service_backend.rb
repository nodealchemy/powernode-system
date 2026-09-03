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
  # backfills a row for the legacy columns on its own, so no existing service
  # changes shape until a PRODUCER adds one — and the first producer write
  # materialises the legacy backend as a row first (.add_instance!), so the
  # original backend keeps its share instead of vanishing behind the set.
  #
  # PRODUCERS (APO-3d, IMP-0c10b9fd5596). Three executors maintain the set
  # through the instance-keyed class methods below, and one MCP verb
  # (SystemIngressTool#set_service_backends, gated) writes it declaratively:
  #
  #   ScaleProjectExecutor    add_replicas    → .add_instance! per new replica
  #                           remove_replicas → .remove_instance! per victim
  #   ReplaceInstanceExecutor                 → .add_instance! (replacement)
  #                                             .drain_instance! (dead member)
  #   ReapInstanceExecutor                    → .remove_instance! (dead member)
  #
  # The three resolve "which services route to this instance" through ONE
  # query (.services_routed_to) and "which of its addresses does this service
  # dial" through ONE rule (.address_for), so the arms cannot disagree about
  # what a replica is to a service.
  #
  # `status` is the drain switch. A "draining" member stays in the table — its
  # history and its weight survive — but leaves the emitted server list, which
  # is what a rolling replacement needs between "stop sending it new work" and
  # "the instance is gone".
  #
  # Draining EVERY member takes the service OUT OF ROTATION (operator ruling
  # 2026-09-02): #load_balanced_backends resolves to no members and
  # Sdwan::ServiceExposureWriter SKIPS the service, reporting it under
  # drained_service_ids (its own key — skipped_service_ids stays the
  # "no host/cert resolvable" list its consumer diagnoses). The earlier fallback — "all draining ⇒ emit the legacy
  # columns" — sent every request to the original host, which after a
  # replace-instance cycle is precisely the one that died. An EMPTY set is a
  # different state and still renders the legacy backend byte-identically.
  class ServiceBackend < ApplicationRecord
    self.table_name = "system_sdwan_service_backends"

    STATUSES = %w[active draining].freeze
    DEFAULT_WEIGHT = 1
    MIN_WEIGHT = 1
    # Matches the sdwan_service_backends_weight_range check constraint. A ceiling
    # exists because Traefik's WRR scheduler allocates per-weight turns; an
    # unbounded weight is a memory/latency footgun, not a finer ratio.
    MAX_WEIGHT = 1000

    # Raised by .add_instance! for an instance that has no address in any form
    # — a pool member not yet addressed, say. Loud on purpose: a producer that
    # silently skipped it would report a scale-out complete while the replica
    # served nothing.
    class NoAddressError < StandardError; end

    # Instance address columns, in the order a producer prefers them AFTER the
    # overlay peer address: the same preference System::NodeInstance#ssh_ip_address
    # applies (overlay VPN, then private, then public).
    INSTANCE_ADDRESS_COLUMNS = %i[vpn_ip_address private_ip_address public_ip_address].freeze

    # Prefix lengths an Sdwan::Peer's assigned_address carries. The allocator
    # stores the address WITH its mask (Sdwan::PrefixAllocator.compose_address_128
    # returns "fd00:…:6/128" and Sdwan::Peer#ensure_assigned_address persists it
    # verbatim), while every backend host — legacy column or member row — is
    # stored bare. Any lookup that goes host → peer must therefore ask for both
    # spellings; comparing the bare form against the column matches nothing on
    # a real fleet.
    PEER_ADDRESS_MASKS = %w[/128 /32].freeze

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
    validate :account_matches_backend_vip
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

    class << self
      # Every host-form address an instance can be dialled on, host only (no
      # prefix, no port): its overlay peer addresses first — that is the form
      # ProvisionFullStackExecutor's peers give a replica and the form a
      # published service dials over the fabric — then its own IP columns.
      def instance_addresses(instance)
        peers = ::Sdwan::Peer.where(node_instance_id: instance.id).order(:created_at)
        overlay = peers.map { |peer| host_only(peer.assigned_address) }
        own = INSTANCE_ADDRESS_COLUMNS.map { |column| host_only(instance.public_send(column)) }
        (overlay + own).compact.uniq
      end

      # The services in `account` that route to `instance`: through their
      # legacy backend_host, through a member row at one of its addresses, or
      # through a backend VIP one of its peers holds. Account-scoped on BOTH
      # tables — a service id alone is no proof the caller may act on it.
      #
      # Ordered by creation so a producer that joins several services does so
      # in a stable order (its outputs are compared across drives).
      def services_routed_to(account:, instance:)
        addresses = instance_addresses(instance)
        peer_ids  = ::Sdwan::Peer.where(node_instance_id: instance.id).pluck(:id)
        vip_ids   = held_vip_ids(account: account, peer_ids: peer_ids)

        services = ::Sdwan::Service.where(account_id: account.id)
        ids  = services.where(backend_host: addresses).pluck(:id)
        ids += services.where(backend_vip_id: vip_ids).pluck(:id) if vip_ids.any?
        rows = where(account_id: account.id)
        ids += rows.where(backend_host: addresses).pluck(:sdwan_service_id)
        ids += rows.where(backend_vip_id: vip_ids).pluck(:sdwan_service_id) if vip_ids.any?

        ::Sdwan::Service.where(id: ids.uniq)
                        .includes(:backend_vip, backends: :backend_vip)
                        .order(:created_at, :id).to_a
      end

      # The subset of .services_routed_to that reaches `instance` BY ADDRESS:
      # through the service's legacy backend_host or through a member row at
      # one of its addresses.
      #
      # THIS, not .services_routed_to, is what the instance-keyed producers act
      # on. A service that reaches the instance only through a backend VIP is
      # left alone by every one of them: a VIP is its own HA mechanism,
      # re-homed by the VIP move / failover, and a host-form row added beside
      # it would count one machine twice in the round robin — the newcomer once
      # in its own right and once more whenever the VIP fails over onto it.
      def host_routed_services(account:, instance:)
        addresses = instance_addresses(instance)
        return [] if addresses.empty?

        services_routed_to(account: account, instance: instance).select do |svc|
          host_forms_of(svc).intersect?(addresses)
        end
      end

      # Adds `instance` as an ACTIVE member of `service`, dialled on
      # .address_for's choice of its addresses and on the service's own port.
      #
      # MATERIALISES FIRST. A service whose set is empty is served by its legacy
      # columns; the moment ONE explicit row exists the legacy backend drops
      # out of #load_balanced_backends. So the first producer write copies the
      # legacy backend into a row of its own before adding the newcomer —
      # otherwise a scale-out from one replica to two would hand ALL traffic to
      # the new one. Idempotent: a row already at that address:port is
      # re-activated (a drained member returning) rather than duplicated.
      #
      # One transaction, so a materialised legacy row cannot outlive a failed
      # add and leave a one-row set that renders exactly as before but now
      # ignores the columns it was copied from.
      def add_instance!(service:, instance:, weight: DEFAULT_WEIGHT)
        address = address_for(service, instance)
        if address.blank?
          raise NoAddressError, "#{instance.name} (#{instance.id}) has no overlay peer address and "                                 "no vpn/private/public address to dial"
        end

        transaction do
          materialise_legacy_backend!(service)

          existing = service.backends.includes(:backend_vip).find do |row|
            row.backend_port == service.backend_port && row.address == address
          end
          if existing
            existing.update!(status: "active") unless existing.status == "active"
            existing
          else
            service.backends.create!(account_id: service.account_id, backend_host: address,
                                     backend_port: service.backend_port, weight: weight)
          end
        end
      end

      # Marks every host-form row at one of the instance's addresses draining.
      # Returns the rows it changed. VIP-form rows are left alone by design:
      # a VIP is its own HA mechanism, re-homed by the VIP move / failover,
      # never by the backend set.
      def drain_instance!(service:, instance:)
        host_rows_for(service, instance).reject { |row| row.status == "draining" }.each do |row|
          row.update!(status: "draining")
        end
      end

      # Destroys every host-form row at one of the instance's addresses.
      # Returns the destroyed rows. Must run BEFORE the instance is terminated:
      # the terminate detaches its peers, and with them the overlay address the
      # rows were resolved from.
      def remove_instance!(service:, instance:)
        host_rows_for(service, instance).each(&:destroy!)
      end

      # Which of the instance's addresses THIS service dials: its peer address
      # on the overlay network the service's existing backend already lives on
      # (so a scaled set stays on one fabric), else the first address
      # .instance_addresses prefers. nil when the instance has none.
      def address_for(service, instance)
        network_id = backend_network_id(service)
        if network_id
          peer = ::Sdwan::Peer.find_by(sdwan_network_id: network_id, node_instance_id: instance.id)
          overlay = host_only(peer&.assigned_address)
          return overlay if overlay.present?
        end

        instance_addresses(instance).first
      end

      private

      def host_only(value)
        text = value.to_s.strip
        return nil if text.empty?

        text.split("/", 2).first
      end

      def held_vip_ids(account:, peer_ids:)
        return [] if peer_ids.empty?

        ::Sdwan::VirtualIp.where(account_id: account.id).select do |vip|
          (Array(vip.holder_peer_ids) + Array(vip.failover_holder_peer_ids)).intersect?(peer_ids)
        end.map(&:id)
      end

      def host_rows_for(service, instance)
        addresses = instance_addresses(instance)
        return [] if addresses.empty?

        service.backends.where(backend_host: addresses).order(:created_at).to_a
      end

      # The overlay network the service's backends live on: the backend VIP's,
      # else the network of any peer whose address the legacy columns or a
      # member row name. nil when the service dials off-overlay hosts.
      #
      # Matched against BOTH spellings of a peer address (PEER_ADDRESS_MASKS):
      # the hosts are bare and `assigned_address` carries its /128, so asking
      # for the bare form alone matched nothing on a real fleet — every
      # host-backed overlay service fell through to .address_for's "first
      # address" fallback and a multi-homed replica could be dialled on the
      # wrong fabric.
      def backend_network_id(service)
        return service.backend_vip.sdwan_network_id if service.backend_vip

        hosts = host_forms_of(service).uniq
        return nil if hosts.empty?

        ::Sdwan::Peer.where(account_id: service.account_id,
                            assigned_address: peer_address_spellings(hosts))
                     .order(:created_at).pick(:sdwan_network_id)
      end

      # Every host-form address this service dials: its legacy column plus each
      # member row's. VIP-form members contribute nothing — their address is
      # the VIP's, resolved separately.
      def host_forms_of(service)
        ([ service.backend_host ] + service.backends.map(&:backend_host)).compact
      end

      # A bare host plus each masked spelling a peer row may carry it under.
      def peer_address_spellings(hosts)
        hosts.flat_map { |host| [ host ] + PEER_ADDRESS_MASKS.map { |mask| "#{host}#{mask}" } }.uniq
      end

      def materialise_legacy_backend!(service)
        return if service.backends.exists?

        service.backends.create!(account_id: service.account_id,
                                 backend_vip_id: service.backend_vip_id,
                                 backend_host: service.backend_host,
                                 backend_port: service.backend_port,
                                 weight: DEFAULT_WEIGHT)
      end
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

    # A backend VIP belonging to another account dials ACROSS the tenant
    # boundary the exposure writer scopes by, and the row's own account_id —
    # inherited from the service — would not show it. The row's account is the
    # service's, so the VIP must be that account's too.
    def account_matches_backend_vip
      return if backend_vip.nil? || account_id.nil?
      return if backend_vip.account_id == account_id

      errors.add(:backend_vip_id, "must belong to the service's account")
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
    # producers (APO-3d: scale-out, DR replace) are exactly the callers that
    # would race here.
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
