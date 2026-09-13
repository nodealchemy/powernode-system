# frozen_string_literal: true

module System
  module Fleet
    # Drops a NodeInstance out of every published service's backend set and
    # regenerates the proxy once, BEFORE the instance is terminated. Returns
    # { removed:, stranded: }.
    #
    # Shared by the two paths that terminate an instance on the fleet's behalf —
    # ReapInstanceExecutor (the destructive half of a DR replace) and the
    # DecisionEngine's abandoned-instance reap (IMP-10c9b9634d4e) — so the order
    # (backends first, then the terminate) and what gets reported cannot drift
    # between them. After the terminate the rows could no longer be found by the
    # instance (it detaches its overlay peer) and would keep the dead host in
    # every set forever.
    #
    # A regen failure is logged, not raised: the rows are gone and the terminate
    # must still happen; the stale on-disk file is what a
    # system_reverse_proxy_compose repairs.
    #
    # STRANDED is the case row removal cannot reach. A published service nobody
    # ever scaled has NO member row — it dials the instance through its legacy
    # backend_host column, which the writer renders verbatim whenever the set is
    # empty. .remove_instance! honestly returns [] for it, so an empty removal
    # list would read as "no published service routed to this instance" while
    # Traefik keeps dialling the host about to be terminated. Rewriting a
    # published service's backend is not the reap's decision to make; REPORTING
    # it is, and the id is what an operator needs to repoint or unpublish the
    # route.
    module ServiceBackendRelease
      module_function

      def release!(account:, instance:, log_tag: name.demodulize)
        services = ::Sdwan::ServiceBackend.host_routed_services(account: account, instance: instance)
        removed = services.flat_map { |svc| ::Sdwan::ServiceBackend.remove_instance!(service: svc, instance: instance) }
                          .map(&:id)
        stranded = services.select do |svc|
          ::Sdwan::ServiceBackend.legacy_route_only?(service: svc, instance: instance)
        end.map(&:id)
        if stranded.any?
          Rails.logger.warn("[#{log_tag}] #{instance.id} is still the LEGACY backend of " \
                            "service(s) #{stranded.join(', ')} — the route outlives the instance")
        end
        return { removed: removed, stranded: stranded } if removed.empty?

        begin
          ::Sdwan::ServiceExposureWriter.write!(account: account)
        rescue ::Sdwan::ServiceExposureWriter::WriteError => e
          Rails.logger.warn("[#{log_tag}] backend rows removed for #{instance.id} but " \
                            "reverse-proxy regen failed: #{e.message}")
        end
        { removed: removed, stranded: stranded }
      end
    end
  end
end
