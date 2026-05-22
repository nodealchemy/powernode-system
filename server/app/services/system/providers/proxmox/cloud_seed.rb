# frozen_string_literal: true

require "yaml"
require "json"

module System
  module Providers
    module Proxmox
      # Renders the cloud-init #cloud-config user-data for a PVE-spawned
      # Powernode-managed VM. The output is paired with the fw-cfg payload
      # (set via PVE's `args` field by ProxmoxProvider#create_vm_instance)
      # — cloud-init handles agent-binary install + systemd unit setup,
      # fw-cfg carries the federation spawn payload (parent_url,
      # acceptance_token, spawn_mode, …). The agent reads fw-cfg on first
      # boot and POSTs the acceptance handshake.
      #
      # Symmetric in intent with System::Providers::LocalQemu::CloudSeed,
      # but renders YAML for cloud-init NoCloud datasource (PVE's
      # mechanism) rather than fw-cfg-only file staging (LocalQemu's).
      class CloudSeed
        DEFAULT_AGENT_URL =
          "https://ops.powernode.org/agent/powernode-agent-linux-amd64"

        # @param spawn_payload [Hash] parent_url, acceptance_token, spawn_mode,
        #   parent_peer_id, contract_version — same shape SpawnPlatformService builds
        # @param hostname [String, nil] VM hostname (default: derived from
        #   spawn_payload's parent_peer_id)
        # @param agent_url [String, nil] override the agent download URL (default
        #   DEFAULT_AGENT_URL, suitable for ops.powernode.org topology)
        # @param ssh_authorized_keys [Array<String>] keys to install for ubuntu user
        # @return [String] YAML user-data ready to write to a snippets file
        def self.render(spawn_payload:, hostname: nil, agent_url: nil,
                        ssh_authorized_keys: [])
          new(
            spawn_payload: spawn_payload,
            hostname: hostname,
            agent_url: agent_url,
            ssh_authorized_keys: ssh_authorized_keys
          ).render
        end

        def initialize(spawn_payload:, hostname: nil, agent_url: nil,
                       ssh_authorized_keys: [])
          @spawn_payload       = spawn_payload || {}
          @hostname            = hostname.presence || derived_hostname
          @agent_url           = agent_url.presence || DEFAULT_AGENT_URL
          @ssh_authorized_keys = Array(ssh_authorized_keys).compact.reject(&:empty?)
        end

        def render
          # Cloud-init expects the literal string `#cloud-config` on the
          # FIRST line (not the YAML header). YAML.dump emits `---` first,
          # so we concatenate manually.
          "#cloud-config\n" + YAML.dump(payload).sub(/\A---\n/, "")
        end

        private

        attr_reader :spawn_payload, :hostname, :agent_url, :ssh_authorized_keys

        def payload
          {
            "hostname"          => hostname,
            "manage_etc_hosts"  => true,
            "package_update"    => false,
            "package_upgrade"   => false,
            "users" => [
              {
                "name"                => "ubuntu",
                "sudo"                => "ALL=(ALL) NOPASSWD:ALL",
                "shell"               => "/bin/bash",
                "ssh_authorized_keys" => ssh_authorized_keys
              }
            ].reject { |u| u["ssh_authorized_keys"].empty? },
            "write_files"       => write_files,
            "runcmd"            => runcmd
          }.compact.tap do |h|
            # Remove users array entirely if empty (don't ship empty users:)
            h.delete("users") if h["users"].nil? || h["users"].empty?
          end
        end

        def write_files
          files = [
            {
              "path"        => "/etc/systemd/system/powernode-agent.service",
              "permissions" => "0644",
              "owner"       => "root:root",
              "content"     => systemd_unit_content
            }
          ]
          # Federation payload disk fallback. PVE restricts the `args` config
          # field (the fw-cfg escape hatch) to root@pam, so API-token spawns
          # can't use fw-cfg. We stage the payload as a JSON file at the
          # canonical PayloadFilePath in extensions/system/agent/internal/federation/config.go;
          # the agent's LoadConfig falls back to this file when fw-cfg yields
          # no parent_url.
          if spawn_payload.is_a?(Hash) && spawn_payload["parent_url"].to_s.length.positive?
            files << {
              "path"        => "/etc/powernode/federation-payload.json",
              "permissions" => "0600",
              "owner"       => "root:root",
              "content"     => JSON.dump(spawn_payload)
            }
          end
          files
        end

        def systemd_unit_content
          <<~UNIT
            [Unit]
            Description=Powernode on-node agent (federation + module reconcile)
            After=network-online.target
            Wants=network-online.target
            ConditionPathExists=/usr/local/bin/powernode-agent

            [Service]
            Type=simple
            ExecStart=/usr/local/bin/powernode-agent service
            Restart=on-failure
            RestartSec=10s
            # Allow reading fw-cfg sysfs
            ReadOnlyPaths=/sys/firmware/qemu_fw_cfg

            [Install]
            WantedBy=multi-user.target
          UNIT
        end

        def runcmd
          [
            # Download the powernode-agent binary from the parent platform
            # (ops). The URL is unauthenticated by design — operators can
            # mirror it onto their own static-asset host if desired.
            "curl -fsSL --retry 3 --retry-delay 5 -o /usr/local/bin/powernode-agent #{agent_url}",
            "chmod +x /usr/local/bin/powernode-agent",
            # First-boot federation accept. The `federation-accept` subcommand
            # reads /etc/powernode/federation-payload.json (cloud-init wrote
            # it via write_files since PVE token-auth can't use fw-cfg) and
            # POSTs the AcceptRequest to parent_url's /federation_api/accept.
            # Standard TLS verification — the parent's cert must be valid for
            # the SAN in parent_url. Operators with internal CAs should pass
            # a CA bundle via --ca-bundle (the platform's mTLS CA when wired).
            "/usr/local/bin/powernode-agent federation-accept || true",
            # Then enable the long-lived service loop (heartbeat, task lease,
            # module reconcile, cert rotation).
            "systemctl daemon-reload",
            "systemctl enable --now powernode-agent.service"
          ]
        end

        def derived_hostname
          peer_id = spawn_payload["parent_peer_id"].to_s
          if peer_id.length >= 8
            "powernode-#{peer_id[0..7]}"
          else
            "powernode-#{SecureRandom.hex(4)}"
          end
        end
      end
    end
  end
end
