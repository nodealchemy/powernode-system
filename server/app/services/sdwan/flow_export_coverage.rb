# frozen_string_literal: true

require "ipaddr"

module Sdwan
  # Sdwan::FlowExportCoverage — per-host answer to "can this machine produce
  # IPFIX flow records, and is anything actually producing them?" (IMP-5a018031cc29)
  #
  # THE DISTINCTION THIS EXISTS TO MAKE
  # -----------------------------------
  # Before this, every consumer of flow telemetry saw one undifferentiated
  # signal: samples, or no samples. Three completely different situations
  # produced the same "no samples":
  #
  #   * a LIGHTWEIGHT (Linux-bridge) host, which cannot export IPFIX at all —
  #     OVS's native exporter is the only source in this architecture and a
  #     Linux bridge has none. The capability is genuinely UNAVAILABLE.
  #   * an OVS host whose exporter was never deployed — the platform was
  #     stamping exporter config onto bridges with no producer to honour it.
  #   * an OVS host whose exporter died.
  #
  # Reporting all three as "nothing observed" is the configured-but-silent
  # failure the SDWAN service-health sensor already conceded. Each state below
  # is a different claim, and `unsupported` is deliberately NOT a gap: nothing
  # is broken on a lightweight host, the feature simply does not exist there.
  #
  # STATES (host-level, most-specific-first evaluation)
  # --------------------------------------------------
  #   unsupported  — no compilable ovs-kind HostBridge. Reason distinguishes
  #                  `linux_bridge_only` (lightweight profile) from
  #                  `no_ovs_bridge` (heavyweight host with none allocated, or
  #                  an explicit kind=linux override). available: false.
  #   unconfigured — capable, but the account holds no active IpfixCollector,
  #                  so TopologyCompiler stamps no exporter block. Nothing is
  #                  expected to be running.
  #   external     — a collector exists but its target address belongs to no
  #                  machine the platform owns. That is an operator-run
  #                  collector; we neither deploy to it nor call the hosts
  #                  broken for pointing at it.
  #   undeployed   — exporter config IS stamped and the producer module is not
  #                  attached. This is the defect the offer named: OVS
  #                  exporting into a void.
  #   unbuilt      — the producer module is attached but has no published
  #                  version, so there is no artifact for composition to
  #                  deliver and nothing will run. This is the state the fleet
  #                  sits in between seeding the catalog row and the operator
  #                  building/publishing it; without it every OVS host would
  #                  read `stalled`, and `stalled` would stop meaning "a
  #                  producer that was working and died".
  #   stalled      — producer deployed, collector has received nothing in the
  #                  window. Deployed and dead.
  #   reporting    — producer deployed and the collector received flows in the
  #                  window.
  #
  # WHAT `reporting` DOES NOT CLAIM
  # -------------------------------
  # Sdwan::FlowSample carries account + collector + the 5-tuple and NO exporter
  # identity, so sample arrival is attributable to a COLLECTOR, never to the
  # host that exported it. `reporting` therefore means "the collector this host
  # exports to is receiving", not "this host's own exporter is alive". With a
  # host-local placement and several hosts, one dead exporter among live ones
  # still reads `reporting`. Stated here rather than papered over; closing it
  # needs an exporter identity on the ingest path, which is filed separately.
  # The distinction the task turns on — unavailable vs. deployed-and-silent —
  # does not depend on it.
  class FlowExportCoverage
    # The producer module seeded by db/seeds/sdwan_flow_exporter_module.rb.
    # Single source of truth for the name: the seed, the deployer and this
    # oracle all read it from here so a rename cannot half-land.
    MODULE_NAME = "sdwan-flow-exporter"

    # How recently the collector must have received a sample for a deployed
    # producer to count as reporting. Matches
    # SdwanServiceHealthSensor::DEFAULT_FLOW_WINDOW_SECONDS — the sensor is the
    # main consumer of these rows, and a coverage window wider than the
    # sensor's would call a producer healthy while the sensor already sees
    # nothing.
    DEFAULT_WINDOW_SECONDS = 900

    STATES = %w[unsupported unconfigured external undeployed unbuilt stalled reporting].freeze
    # States in which the platform expects a producer process to be running.
    EXPECTING_STATES = %w[undeployed unbuilt stalled reporting].freeze
    # States that represent a real deployment GAP an operator should close.
    # `unsupported` and `external` are excluded on purpose: neither is a fault.
    GAP_STATES = %w[undeployed unbuilt stalled].freeze

    # Where the producer has to run for a given account's collector.
    #   :unconfigured — no active collector, nothing to place.
    #   :host_local   — collector target is a loopback address, so every
    #                   exporting host must run its own producer.
    #   :fleet_host   — the target address is one of this account's peers, so
    #                   exactly that machine runs the producer.
    #   :external     — the target belongs to nothing we manage.
    Placement = Struct.new(:mode, :node_ids, :collector, :reason, keyword_init: true)

    def self.for_account(account, window_seconds: DEFAULT_WINDOW_SECONDS)
      new(account, window_seconds: window_seconds).entries
    end

    def self.placement_for(account)
      new(account).placement
    end

    def self.summary(account, window_seconds: DEFAULT_WINDOW_SECONDS)
      new(account, window_seconds: window_seconds).summary
    end

    def initialize(account, window_seconds: DEFAULT_WINDOW_SECONDS)
      @account = account
      @window_seconds = window_seconds
    end

    # { node_instance_id => entry_hash }.
    def entries
      @entries ||= hosts.index_by(&:id).transform_values { |instance| entry_for(instance) }
    end

    def summary
      by_state = Hash.new(0)
      unsupported = []
      gaps = []

      entries.each do |instance_id, entry|
        by_state[entry[:state]] += 1
        unsupported << instance_id if entry[:state] == "unsupported"
        gaps << instance_id if GAP_STATES.include?(entry[:state])
      end

      {
        placement: placement.mode.to_s,
        collector_id: collector&.id,
        window_seconds: @window_seconds,
        by_state: by_state,
        unsupported_host_ids: unsupported,
        gap_host_ids: gaps
      }
    end

    # The nodes the producer module must be attached to, or [] when the
    # platform is not the producer's owner.
    def target_node_ids
      placement.node_ids
    end

    # An attached module with no published version has no artifact for
    # composition to deliver, so nothing runs on the host no matter how many
    # assignments point at it. `versioned` is System::NodeModule's own scope
    # for this (`where.not(current_version_id: nil)`).
    def producer_built?
      return @producer_built if defined?(@producer_built)

      @producer_built = ::System::NodeModule.versioned
                                            .exists?(account_id: @account.id, name: MODULE_NAME)
    end

    def placement
      @placement ||= resolve_placement
    end

    def collector
      return @collector if defined?(@collector)

      @collector = ::Sdwan::IpfixCollector.for_account(@account)
                                          .active
                                          .order(:created_at)
                                          .first
    end

    private

    # Every instance the account still owns. `terminated` is excluded because a
    # destroyed machine is not a coverage gap; every other status is included,
    # since a stopped or provisioning OVS host still has a producer story.
    def hosts
      @hosts ||= ::System::NodeInstance.where(account_id: @account.id)
                                       .where.not(status: "terminated")
                                       .order(:created_at)
                                       .to_a
    end

    # Capability is read off the SAME predicate TopologyCompiler.host_bridges_for
    # stamps the `ipfix:` block on — compilable AND kind == "ovs". Deriving it
    # from network_profile instead would misreport a heavyweight host whose only
    # bridge was explicitly allocated kind=linux (HostBridgeAllocator supports
    # that override), which is precisely a host that receives no exporter config.
    def ovs_host_ids
      @ovs_host_ids ||= ::Sdwan::HostBridge.where(node_instance_id: hosts.map(&:id))
                                           .compilable
                                           .where(kind: "ovs")
                                           .distinct
                                           .pluck(:node_instance_id)
                                           .to_set
    end

    # ENABLED assignments only. System::Runtime::SyncModules commits
    # `node_module_assignments.where(enabled: true)`, so a disabled row
    # delivers nothing to the host — counting it as deployed would report a
    # host an operator deliberately switched off as `stalled` ("deployed and
    # dead") instead of `undeployed`, which is the same false-actuation claim
    # this class exists to prevent.
    def deployed_node_ids
      @deployed_node_ids ||= ::System::NodeModuleAssignment
                               .enabled
                               .joins(:node_module)
                               .where(system_node_modules: { account_id: @account.id, name: MODULE_NAME })
                               .distinct
                               .pluck(:node_id)
                               .to_set
    end

    def last_sample_at
      return @last_sample_at if defined?(@last_sample_at)

      @last_sample_at =
        if collector.nil?
          nil
        else
          ::Sdwan::FlowSample.where(ipfix_collector_id: collector.id)
                             .where(observed_at: @window_seconds.seconds.ago..)
                             .maximum(:observed_at)
        end
    end

    def base_entry(instance)
      {
        node_instance_id: instance.id,
        node_id: instance.node_id,
        name: instance.name,
        network_profile: instance.network_profile,
        collector_id: collector&.id,
        collector_endpoint: collector&.target_endpoint,
        placement: placement.mode.to_s,
        window_seconds: @window_seconds,
        last_sample_at: nil
      }
    end

    def entry_for(instance)
      entry = base_entry(instance)

      unless ovs_host_ids.include?(instance.id)
        return entry.merge(
          state: "unsupported",
          reason: instance.network_profile == "lightweight" ? "linux_bridge_only" : "no_ovs_bridge",
          available: false,
          exporter_expected: false,
          exporter_deployed: false
        )
      end

      entry = entry.merge(available: true)

      case placement.mode
      when :unconfigured
        return entry.merge(state: "unconfigured", reason: "no_active_collector",
                           exporter_expected: false, exporter_deployed: false)
      when :external
        return entry.merge(state: "external", reason: placement.reason,
                           exporter_expected: false, exporter_deployed: false)
      end

      # host_local: this host must run it. fleet_host: one named machine does,
      # and every exporting host depends on that one.
      responsible_node_ids =
        placement.mode == :host_local ? [ instance.node_id ] : placement.node_ids
      deployed = responsible_node_ids.any? { |node_id| deployed_node_ids.include?(node_id) }

      unless deployed
        return entry.merge(state: "undeployed", reason: "producer_module_not_attached",
                           exporter_expected: true, exporter_deployed: false)
      end

      unless producer_built?
        return entry.merge(state: "unbuilt", reason: "producer_module_has_no_published_version",
                           exporter_expected: true, exporter_deployed: true)
      end

      if last_sample_at
        entry.merge(state: "reporting", reason: nil, exporter_expected: true,
                    exporter_deployed: true, last_sample_at: last_sample_at)
      else
        entry.merge(state: "stalled", reason: "no_samples_in_window",
                    exporter_expected: true, exporter_deployed: true)
      end
    end

    def resolve_placement
      return Placement.new(mode: :unconfigured, node_ids: [], collector: nil,
                           reason: "no_active_collector") if collector.nil?

      address = bare_host(collector.host)

      if loopback?(address)
        return Placement.new(mode: :host_local, node_ids: ovs_node_ids, collector: collector,
                             reason: nil)
      end

      node_id = peer_node_id_for(address)
      if node_id
        return Placement.new(mode: :fleet_host, node_ids: [ node_id ], collector: collector,
                             reason: nil)
      end

      Placement.new(mode: :external, node_ids: [], collector: collector,
                    reason: "collector_target_off_fleet")
    end

    def ovs_node_ids
      hosts.select { |i| ovs_host_ids.include?(i.id) }.map(&:node_id).uniq
    end

    # Strips the OVS/WireGuard bracket form an operator may have pasted in;
    # Sdwan::IpfixCollector#host validates presence only, so "[fd00::1]" is a
    # storable value (see Sdwan::HostPort).
    def bare_host(raw)
      value = raw.to_s.strip
      value = value[1..-2].to_s if value.start_with?("[") && value.end_with?("]")
      value
    end

    # Loopback is the ONE address family where "the exporter is on this host"
    # is a fact rather than a guess. Everything else goes through the peer
    # lookup below, which is exact, or falls out as external. No heuristics on
    # private-range membership: fd00::/8 is the account's own fabric AND a
    # perfectly ordinary address for someone else's collector.
    def loopback?(address)
      return false if address.blank?

      IPAddr.new(address).loopback?
    rescue IPAddr::InvalidAddressError, ArgumentError
      false
    end

    # An address is "on the fleet" only when it is literally a peer's
    # assigned_address in THIS account. Exact, not inferred — the same
    # standard SdwanServiceHealthSensor holds itself to when it declines to
    # test VIP containment against a prefix nothing validates.
    def peer_node_id_for(address)
      return nil if address.blank?
      return nil unless valid_address?(address)

      # assigned_address is a plain string column, so an exact match alone
      # misses a non-canonical spelling of the same address ("fd00::0005" vs
      # "fd00::5"). Both spellings go into ONE indexed lookup rather than a
      # scan: the miss path here is the COMMON path (every off-fleet collector
      # target reaches it), and walking every peer in the account to conclude
      # "external" would put an unbounded scan on the collector-create path.
      peer = ::Sdwan::Peer.where(account_id: @account.id)
                          .where(assigned_address: address_spellings(address))
                          .first
      peer&.node_instance&.node_id
    end

    def address_spellings(address)
      canonical = IPAddr.new(address).to_s
      [ address, canonical, "[#{canonical}]" ].uniq
    rescue IPAddr::InvalidAddressError, ArgumentError
      [ address ]
    end

    def valid_address?(address)
      IPAddr.new(address)
      true
    rescue IPAddr::InvalidAddressError, ArgumentError
      false
    end
  end
end
