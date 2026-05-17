# frozen_string_literal: true

module System
  module Providers
    module LocalQemu
      # Generates the per-instance bootstrap seed: issues a BootstrapToken,
      # resolves the CA cert + image_base, and assembles the virtio-fw-cfg
      # entries the agent's identity package reads at first boot.
      #
      # The agent's `internal/identity/fwcfg.go` reads from
      #   /sys/firmware/qemu_fw_cfg/by_name/opt/com.powernode/<key>
      # so the keys here must be in `opt/com.powernode/<name>` form.
      #
      # Reference: Golden Eclipse plan M4 — providers/local_qemu/cloud_init_seed.
      # Despite the plan's filename, we use fw-cfg (faster, no separate ISO)
      # rather than cloud-init's NoCloud datasource. The legacy AWS/GCP/Azure
      # paths still use cloud-init via their providers.
      class CloudSeed
        Result = Struct.new(:bootstrap_token_id, :fw_cfg_entries, :image_base, keyword_init: true)

        class EnrollmentSeedError < StandardError; end

        def self.build(instance:, options: {})
          new.build(instance: instance, options: options)
        end

        # Filesystem location DomainXmlBuilder references in the
        # <qemu:arg value='name=...,file=...'/> entries. Override via
        # POWERNODE_FWCFG_DIR for ephemeral test runs.
        FWCFG_DIR = ENV.fetch("POWERNODE_FWCFG_DIR", "/var/run/powernode-fwcfg")

        def build(instance:, options: {})
          bootstrap_token, plaintext = issue_bootstrap_token(instance)
          ca_pem = resolve_ca_pem
          image_base = resolve_image_base(options)

          entries = {
            "opt/com.powernode/instance_uuid" => instance.id,
            "opt/com.powernode/instance_name" => instance.name.to_s,
            "opt/com.powernode/bootstrap_token" => plaintext,
            "opt/com.powernode/ca_pem" => ca_pem,
            "opt/com.powernode/platform_url" => platform_url
          }

          # If the operator pre-staged the agent binary at a known path on
          # the host, surface it via fw-cfg so the agent can self-update
          # to the matching version on first boot.
          if (agent_url = options[:agent_url] || ENV["POWERNODE_AGENT_URL"])
            entries["opt/com.powernode/agent_url"] = agent_url
          end

          # Federation spawn payload — when this NodeInstance is being
          # provisioned as a spawned child platform, the parent's
          # SpawnPlatformService injects the payload via
          # options[:spawn_payload] or stashes it in
          # instance.config["federation_spawn"]. The agent's first-run
          # handler reads these to POST /federation_api/accept to the
          # parent. Plan reference: Decentralized Federation §H + P6.7.
          spawn_payload = options[:spawn_payload] ||
                          (instance.respond_to?(:config) ? instance.config&.dig("federation_spawn") : nil)
          if spawn_payload.is_a?(Hash) && spawn_payload["parent_url"].present?
            entries["opt/com.powernode/parent_url"]        = spawn_payload["parent_url"].to_s
            entries["opt/com.powernode/acceptance_token"]  = spawn_payload["acceptance_token"].to_s
            entries["opt/com.powernode/spawn_mode"]        = spawn_payload["spawn_mode"].to_s
            entries["opt/com.powernode/parent_peer_id"]    = spawn_payload["parent_peer_id"].to_s
            entries["opt/com.powernode/contract_version"]  = (spawn_payload["contract_version"] || "v1").to_s
          end

          # SDWAN peer hint: when the NodeInstance has a Sdwan::Peer row
          # bound to it (via Sdwan::PeerEnroller), surface the peer + network
          # IDs so the agent (post-enrollment, with its issued mTLS cert)
          # can call the node-API to fetch its WG config + the network's
          # hub peer list. The peer's private key stays in Vault and is
          # released only against the cert, never via fw-cfg directly.
          if defined?(::Sdwan::Peer)
            sdwan_peer = ::Sdwan::Peer.where(node_instance_id: instance.id).order(created_at: :desc).first
            if sdwan_peer
              entries["opt/com.powernode/sdwan_peer_id"]    = sdwan_peer.id
              entries["opt/com.powernode/sdwan_network_id"] = sdwan_peer.sdwan_network_id
              entries["opt/com.powernode/sdwan_overlay_ip"] = sdwan_peer.assigned_address.to_s
            end
          end

          # Stage each entry to disk. DomainXmlBuilder references these by
          # path so libvirt's apparmor/selinux policy doesn't complain about
          # large inline values (CA cert can exceed cmdline arg limits too).
          stage_fw_cfg_files!(entries) unless options[:skip_fwcfg_stage]

          {
            bootstrap_token_id: bootstrap_token&.id,
            fw_cfg_entries: entries,
            image_base: image_base
          }
        end

        private

        def issue_bootstrap_token(instance)
          return [ nil, options_test_token ] unless defined?(::System::BootstrapToken)

          ::System::BootstrapToken.issue!(
            node: instance.node,
            node_instance: instance,
            intended_subject: instance.id,
            ttl: 1.hour,
            purpose: "local_qemu_provision"
          )
        rescue StandardError => e
          Rails.logger.warn("[LocalQemu::CloudSeed] BootstrapToken.issue! failed: #{e.message}")
          [ nil, options_test_token ]
        end

        # Test fallback when BootstrapToken model isn't available or token
        # issuance fails. Provides a deterministic placeholder so the
        # provider tests can assert on entry shape without DB churn.
        def options_test_token
          "test-token-#{SecureRandom.hex(8)}"
        end

        def resolve_ca_pem
          # InternalCaService.ca_chain_pem returns the platform CA chain via
          # the active adapter (LocalCaAdapter in dev/test, VaultCaAdapter in
          # production). Falls back to inline PEM only if the service is
          # genuinely absent (e.g. running outside the Rails autoload tree).
          if defined?(::System::InternalCaService) && ::System::InternalCaService.respond_to?(:ca_chain_pem)
            ::System::InternalCaService.ca_chain_pem
          else
            ENV["POWERNODE_CA_PEM"] || "-----BEGIN CERTIFICATE-----\nFIXTURE\n-----END CERTIFICATE-----"
          end
        rescue StandardError => e
          Rails.logger.warn("[CloudSeed] resolve_ca_pem fell back to fixture: #{e.message}")
          ENV["POWERNODE_CA_PEM"] || "-----BEGIN CERTIFICATE-----\nFIXTURE-fallback\n-----END CERTIFICATE-----"
        end

        def resolve_image_base(options)
          options[:image_base] || ENV["POWERNODE_IMAGE_BASE"] ||
            "/var/lib/powernode/images"
        end

        # Resolution order:
        #   1. ENV (set by systemd from /etc/powernode/backend-default.conf in
        #      production; this is the canonical value)
        #   2. The existing fwcfg file (preserves a previously-staged value
        #      across re-seeds — avoids the foot-gun where running CloudSeed
        #      from a shell without the env clobbers a working platform URL)
        #   3. Test default — only allowed in test env
        #
        # In production-shaped invocations without env, we raise instead of
        # silently defaulting: a wrong URL bricks every newly-booted VM, so a
        # loud failure at seed time is preferable to a quiet 5-second
        # connection-refused crash loop on the guest.
        def platform_url
          env_value = ENV["POWERNODE_PLATFORM_URL"].presence
          return env_value if env_value

          on_disk = read_existing_platform_url
          return on_disk if on_disk

          if Rails.env.test?
            "http://localhost:3000"
          else
            raise EnrollmentSeedError,
                  "POWERNODE_PLATFORM_URL is not set and no existing fwcfg " \
                  "platform_url file is present at #{File.join(FWCFG_DIR, 'opt_com.powernode_platform_url')}. " \
                  "Set the env var (sourced from /etc/powernode/backend-default.conf in production) before " \
                  "calling CloudSeed.build."
          end
        end

        def read_existing_platform_url
          path = File.join(FWCFG_DIR, "opt_com.powernode_platform_url")
          return nil unless File.exist?(path)

          value = File.read(path).strip
          return nil if value.empty?
          return nil if value == "http://localhost:3000" && !Rails.env.test? # known-bad sentinel from prior bad seeds

          value
        rescue StandardError
          nil
        end

        # Write each fw-cfg entry to disk so DomainXmlBuilder's
        # `name=...,file=...` references resolve. Mode 0644 because qemu
        # may run as a different user under qemu:///system; 0755 dir to
        # let libvirt's discovery probe enumerate.
        def stage_fw_cfg_files!(entries)
          require "fileutils"
          FileUtils.mkdir_p(FWCFG_DIR, mode: 0o755)
          entries.each do |key, value|
            file_path = File.join(FWCFG_DIR, key.gsub("/", "_"))
            File.write(file_path, value.to_s)
            File.chmod(0o644, file_path)
          end
        rescue Errno::EACCES => e
          # Fall back to /tmp when /var/run isn't writable (test runs as
          # non-root). Mutate FWCFG_DIR for this process; DomainXmlBuilder
          # reads the same constant. NB: the const-rebind is intentional —
          # it scopes a per-process runtime override.
          fallback = File.join(Dir.tmpdir, "powernode-fwcfg-#{Process.uid}")
          FileUtils.mkdir_p(fallback, mode: 0o755)
          self.class.send(:remove_const, :FWCFG_DIR)
          self.class.const_set(:FWCFG_DIR, fallback)
          Rails.logger.warn("[CloudSeed] FWCFG_DIR fallback to #{fallback} (#{e.message})")
          retry
        end
      end
    end
  end
end
