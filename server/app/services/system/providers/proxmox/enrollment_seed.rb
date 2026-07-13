# frozen_string_literal: true

module System
  module Providers
    module Proxmox
      # Builds the platform-identity fw-cfg entries a pool-provisioned
      # Proxmox uefi_disk builder needs to auto-enroll on first boot.
      #
      # Mirrors System::Providers::LocalQemu::CloudSeed's identity block
      # (instance_uuid, instance_name, bootstrap_token, ca_pem,
      # platform_url) — ONLY those 5 entries. This is deliberately narrow:
      # System::Providers::Proxmox::CloudSeed is a *different*, unrelated
      # class (the cicustom/federation cloud-init YAML renderer) and is
      # untouched by this change.
      #
      # Root cause this fixes: create_uefi_disk_vm_instance never staged
      # any fw-cfg at all, so an automated (pool-replenished) uefi_disk
      # builder booted with no platform_url/token/ca and could never
      # enroll — it would sit at pool_state="warming" forever, because
      # nothing ever promotes an unenrolled instance to "ready" either
      # (see the separate heartbeat-driven promotion fix in
      # StatusController#heartbeat).
      #
      # Opt-in / fail-safe gate: #build returns nil unless BOTH the CA
      # chain AND the platform URL resolve (see #resolve_enroll_ca_pem +
      # #resolve_platform_url). An operator who hasn't configured
      # enrollment identity gets EXACTLY the pre-fix behavior — the
      # provider proceeds without staging any identity fw-cfg. This is
      # deliberate, not a shortcut: a builder pointed at the wrong CA
      # fails its TLS handshake to the platform SILENTLY on the guest
      # side (no operator-visible error surfaces), so we never guess or
      # fall back to an internal CA default — see the resolver below.
      class EnrollmentSeed
        def self.build(instance:)
          new.build(instance: instance)
        end

        def build(instance:)
          ca_pem = resolve_enroll_ca_pem
          platform_url = resolve_platform_url

          if ca_pem.blank? || platform_url.blank?
            Rails.logger.warn(
              "[Proxmox::EnrollmentSeed] enrollment identity not staged for #{instance.id}: " \
              "set SiteSetting system.ci_builder.enroll_ca_pem (trust chain of the platform URL, " \
              "e.g. the LE chain) + system.ci_builder.enroll_platform_url"
            )
            return nil
          end

          bootstrap_token, plaintext = issue_bootstrap_token(instance)

          entries = {
            "opt/com.powernode/instance_uuid"   => instance.id,
            "opt/com.powernode/instance_name"   => instance.name.to_s,
            "opt/com.powernode/bootstrap_token" => plaintext,
            "opt/com.powernode/ca_pem"          => ca_pem,
            "opt/com.powernode/platform_url"    => platform_url
          }

          { fw_cfg_entries: entries, bootstrap_token_id: bootstrap_token&.id }
        end

        private

        def issue_bootstrap_token(instance)
          ::System::BootstrapToken.issue!(
            node: instance.node,
            node_instance: instance,
            intended_subject: instance.id,
            ttl: 1.hour,
            purpose: "proxmox_uefi_provision"
          )
        end

        # DO EXACTLY THIS — no fallbacks beyond the two listed here, ever.
        # NEVER fall back to InternalCaService/an internal CA default: a
        # builder dialing a public-LE edge (e.g. dev.ipnode.us) needs the
        # LE chain, and a wrong/internal CA default fails enrollment TLS
        # SILENTLY on the guest. ca_pem is a PUBLIC cert chain (not
        # secret) but correctness here is safety-critical.
        def resolve_enroll_ca_pem
          configured = ::SiteSetting.get("system.ci_builder.enroll_ca_pem").presence ||
                       ENV["POWERNODE_ENROLL_CA_PEM"].presence
          return configured if configured

          nil
        end

        # Same two-source resolution LocalQemu::CloudSeed uses for its
        # platform_url (SiteSetting/ENV, no on-disk fallback — this path
        # has no prior fwcfg staging directory to read back from). Unlike
        # ca_pem, an unresolved platform_url isn't a silent-TLS-failure
        # risk by itself, but without it there is nowhere to enroll
        # against — same opt-in gate applies.
        def resolve_platform_url
          ::SiteSetting.get("system.ci_builder.enroll_platform_url").presence ||
            ENV["POWERNODE_ENROLL_PLATFORM_URL"].presence ||
            ENV["POWERNODE_PLATFORM_URL"].presence
        end
      end
    end
  end
end
