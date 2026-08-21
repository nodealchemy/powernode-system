# frozen_string_literal: true

module Sdwan
  # The bracket-v6 "host:port" expression, for the SDWAN/federation surfaces
  # that consume it.
  #
  # Six sites hand-rolled it before this module existed (IMP-9537a74e50fa):
  # Sdwan::Peer.format_host_port, Sdwan::Service#backend_url,
  # Federation::TcpForwarderConfigWriter#backend_address,
  # Sdwan::IpfixCollector#target_endpoint, Sdwan::NatCompiler#build_rule and
  # System::Ai::Skills::SdwanIpfixCollectorComposeExecutor#projected_endpoint.
  # Three of the six (the last three) omitted the already-bracketed guard and
  # emitted "[[fd00::1]]:4739"; all six now route through here.
  #
  # It lives here rather than on Sdwan::Peer because the consumers are a NAT
  # compiler, an IPFIX collector, a federation config writer and a skill
  # executor, none of which has any business loading a peer row's model class.
  #
  # NOT yet exhaustive, and deliberately so — two families were left outside
  # this change's blast radius and are named here so they cannot be forgotten:
  #
  #   * System::InferenceDeploymentService#http_url is a SEVENTH copy of this
  #     exact expression (with a hardcoded "http" scheme) and still carries the
  #     double-bracket bug. Its fallback host is an unvalidated provider-reported
  #     instance IP, so the bug is reachable there. Folding it in needs its own
  #     red test and was not in this task's approved scope.
  #   * Federation::ServiceRouteWriter and Sdwan::ServiceExposureWriter emit
  #     "#{host}:#{port}" with NO bracketing at all — a different expression,
  #     documented at TcpForwarderConfigWriter#backend_address as a deliberate
  #     divergence. That rationale is asserted, not demonstrated.
  #
  # Two rules, and both matter:
  #
  # 1. Bracket only an IPv6 LITERAL — never on a declared address family. The
  #    columns that feed this hold hostnames too (Sdwan::Peer's
  #    endpoint_host_v6_must_be_v6_or_hostname explicitly accepts a hostname in
  #    the v6 column because DNS hands back the AAAA; Sdwan::Service#backend_host
  #    is free-form enough that the model has an "unobservable" health state for
  #    exactly that case). "[edge.example.net]:51820" is not an address anyone
  #    can dial. Presence of ":" is the only honest literal test here.
  #
  # 2. Do not re-bracket an ALREADY-bracketed host. Every producer feeding this
  #    admits the bracketed form — Peer's validation guards with `include?(":")`,
  #    which "[fd00::1]" satisfies; Sdwan::IpfixCollector#host carries
  #    `presence: true` and no format validation at all; a federation
  #    subscription's backend_vip is an unvalidated string filled from a REMOTE
  #    peer's offering. And bracketed is precisely the form an operator copies
  #    out of a WireGuard or collector config. Re-bracketing blindly yields
  #    "[[fd00::1]]:51820", which nothing downstream parses: WireGuard rejects
  #    it, ovs-vsctl rejects it, and the Go forwarder hands Backend straight to
  #    net.Dial (agent/internal/tcpfwd/forwarder.go), whose internal host/port
  #    split rejects it.
  #
  # Named #join rather than #format so it cannot shadow Kernel#format for this
  # module's own singleton.
  module HostPort
    def self.join(host, port)
      host = host.to_s
      host = "[#{host}]" if host.include?(":") && !host.start_with?("[")
      "#{host}:#{port}"
    end
  end
end
