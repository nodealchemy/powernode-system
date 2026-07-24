# frozen_string_literal: true

module System
  module Autonomy
    # RCP v2 (campaign 019f9250, increment p0c) — INV-2: boot never depends
    # on the network. Boot target must be a locally-resident, pinned image;
    # no DNS/fetch/control-plane call on the critical boot path. Updates are
    # pulled + reconciled only AFTER a healthy boot.
    #
    # Concrete, already-known hazard this check targets: PVE's `cicustom`
    # cloud-init channel (System::Providers::ProxmoxProvider#stage_cicustom)
    # writes the guest's user-data/meta-data/network-config as snippet FILES
    # onto a shared NFS storage (default "dsm-data" at
    # /mnt/pve-data/snippets — see that method's doc comment, which
    # literally names "the Powernode-platform-on-ops shape" as the default
    # assumption). At boot, PVE's cloud-init drive needs that NFS mount
    # reachable to construct the guest's NoCloud seed — a boot-time network
    # (NFS) dependency, for exactly the pivot-boot modes (`uefi_disk`,
    # `direct_kernel`) that exist specifically to satisfy INV-2 otherwise.
    #
    # The codebase already ships the fix as an opt-in per-connection
    # transport: ProxmoxProvider#cidata_iso_transport? / the class-level
    # ProxmoxProvider.cidata_iso_transport_for?(config) — building the
    # NoCloud seed as an ISO uploaded via the token-authenticated PVE
    # storage API and attached as a CD-ROM, so the resulting guest's
    # cloud-init data is baked onto its OWN attached disk, not fetched over
    # NFS at boot. This module re-derives that SAME predicate (delegating to
    # the provider's own public class method — no duplicated logic, no drift
    # risk) to decide whether a given (boot_mode, provider config) pairing
    # is INV-2-compliant, so it can be checked BEFORE provisioning commits.
    #
    # Deliberately advisory-by-default / opt-in-strict, not a blanket hard
    # reject: today's default Proxmox connection ("IPNode-PVE") has no
    # `cidata_transport: "iso"` override, and per ProxmoxProvider's own
    # comments, federation spawns using uefi_disk boot_mode currently ride
    # this SAME NFS cicustom channel as an intentional, working delivery
    # path ("Federation payload delivery ... rides the same cloud-init/
    # cicustom channel as cloud_init, which is API-token-safe"). Hard-
    # rejecting unconditionally could break that live flow — a live
    # behavior change this increment must not make unilaterally. Strict
    # (raising) enforcement is opt-in via `strict: true`, intended for
    # RCP-aware callers provisioning an actual consensus-member node (P1-a/
    # P1-d); the non-strict path still surfaces the violation (for the
    # fleet-wide scan / logs) without blocking existing traffic.
    module BootPathInvariantCheck
      PIVOT_BOOT_MODES = %w[uefi_disk direct_kernel].freeze

      class BootPathViolation < StandardError; end

      module_function

      # provider_type: e.g. "proxmox" (adapter.provider_type) — only Proxmox
      #   is known to have this specific NFS-cicustom hazard today; other
      #   providers are unaffected until they grow an equivalent mechanism.
      # boot_mode: the resolved boot_mode string ("cloud_init" default,
      #   "uefi_disk", "direct_kernel").
      # provider_config: the resolved System::ProviderConnection#config Hash
      #   (adapter.connection.config) — READ-ONLY, no live call. Deliberately
      #   NOT System::Provider#config: ProxmoxProvider#cidata_iso_transport?
      #   reads only the connection's own config, with no fallback to its
      #   parent Provider (unlike default_storage, which does fall back —
      #   see StorageLocalityCheck / ProxmoxProvider#pve_credential). Passing
      #   the Provider's config here would silently miss a connection-level
      #   override.
      # payload_present: true when this provision would actually stage a
      #   cicustom payload (params[:user_data] or params[:meta_data]
      #   present / would be auto-rendered) — an instance with no payload at
      #   all never touches the NFS channel in the first place.
      def network_dependent_boot?(provider_type:, boot_mode:, provider_config:, payload_present:)
        return false unless provider_type.to_s == "proxmox"
        return false unless PIVOT_BOOT_MODES.include?(boot_mode.to_s)
        return false unless payload_present
        return false if defined?(::System::Providers::ProxmoxProvider) &&
                         ::System::Providers::ProxmoxProvider.cidata_iso_transport_for?(provider_config)

        true
      end

      # Returns a violation descriptor Hash (nil if compliant) — the
      # non-raising form used by the fleet-wide scan.
      def violation_for(provider_type:, boot_mode:, provider_config:, payload_present:, node: nil)
        return nil unless network_dependent_boot?(
          provider_type: provider_type, boot_mode: boot_mode,
          provider_config: provider_config, payload_present: payload_present
        )

        {
          invariant: "INV-2",
          severity: :high,
          node_id: node&.id,
          node_name: node&.name,
          boot_mode: boot_mode.to_s,
          detail: "boot-time identity delivery depends on the NFS-backed cicustom snippets " \
                  "channel (no cidata_transport: \"iso\" opt-in on the provider connection) " \
                  "— the boot-critical path is not local/pinned per INV-2"
        }
      end

      # Raising counterpart. Only raises when `strict` — see the module doc
      # for why this is opt-in rather than an unconditional hard reject.
      def assert_local_boot!(provider_type:, boot_mode:, provider_config:, payload_present:, strict:)
        return unless strict

        violation = violation_for(
          provider_type: provider_type, boot_mode: boot_mode, provider_config: provider_config,
          payload_present: payload_present
        )
        return unless violation

        raise BootPathViolation, "refusing boot_mode=#{boot_mode} provision: #{violation[:detail]}"
      end
    end
  end
end
