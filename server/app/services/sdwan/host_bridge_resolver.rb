# frozen_string_literal: true

# Sdwan::HostBridgeResolver — read-side helper that returns the
# kernel-visible name of the platform-managed bridge a given host
# should attach VMs (and other intra-node tap consumers) to.
#
# This is the SINGLE SOURCE OF TRUTH for the bridge name on the
# platform side. Consumers (DomainXmlBuilder, container runtime
# applier, future K8s CNI scaffolding) MUST go through this service
# rather than read configuration directly — that way switching from
# the lightweight (linux) profile to the heavyweight (ovs) profile in
# Phase O2 swaps a single resolver branch instead of every consumer.
#
# Resolution rules:
#   * The bridge MUST be active (or draining — still reachable during
#     teardown grace window). pending/removed rows are not eligible.
#   * If a host has multiple compilable bridges (Phase O2+ multi-tenant
#     scenario), the first by short_id wins for the default lookup.
#     Callers needing a specific kind use #bridge_name_for_kind.
#   * NO FALLBACK to the legacy hardcoded `pwnvbr0` — the clean break
#     forces the operator/AI fleet to allocate a HostBridge before VMs
#     can be provisioned in routed mode. Missing-bridge errors carry
#     the host id so operators can run the allocator and retry.
#
# Phase O1 of the OVS+OVN dual-profile roadmap (lightweight track).
module Sdwan
  class HostBridgeResolver
    class NoBridgeForHost < StandardError; end

    # Returns the kernel-visible bridge name (e.g. "pwnbr-1") for the
    # given host. Raises NoBridgeForHost if no compilable HostBridge
    # exists — callers must allocate one via Sdwan::HostBridgeAllocator
    # before retrying.
    def self.bridge_name_for(host)
      bridge_for(host).bridge_name
    end

    # Returns the kernel-visible bridge name for the given host filtered
    # to a specific kind ("linux" | "ovs"). Used by Phase O2+ heavyweight
    # paths that explicitly require an OVS bridge regardless of any
    # additional Linux bridges the host might also carry.
    def self.bridge_name_for_kind(host, kind:)
      bridge_for(host, kind: kind).bridge_name
    end

    # Returns the HostBridge row itself. Useful when callers need the
    # CIDR or other addressing metadata in addition to the name.
    def self.bridge_for(host, kind: nil)
      raise NoBridgeForHost, "host argument is required" if host.nil?

      scope = ::Sdwan::HostBridge
                .for_host(host)
                .compilable
                .order(:short_id)
      scope = scope.where(kind: kind.to_s) if kind

      bridge = scope.first
      return bridge if bridge

      detail = kind ? " (kind=#{kind})" : ""
      raise NoBridgeForHost,
            "no active Sdwan::HostBridge for host #{host.id}#{detail} — " \
            "allocate one via Sdwan::HostBridgeAllocator.allocate!(host:) " \
            "before provisioning routed-mode VMs on this host"
    end

    # True when an active/draining bridge exists for this host. Lets
    # callers branch on availability without rescuing the error case.
    def self.bridge_present?(host, kind: nil)
      return false if host.nil?

      scope = ::Sdwan::HostBridge.for_host(host).compilable
      scope = scope.where(kind: kind.to_s) if kind
      scope.exists?
    end
  end
end
