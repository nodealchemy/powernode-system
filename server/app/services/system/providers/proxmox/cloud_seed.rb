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
        # Path on the parent platform that serves the agent binary. The
        # `/agent/*` Traefik router maps this prefix to powernode-backend
        # on the non-mTLS entrypoint (:443); Rails serves the file from
        # public/agent/ (symlinked to extensions/system/agent/dist/).
        DEFAULT_AGENT_PATH = "/agent/powernode-agent-linux-amd64"

        # @param spawn_payload [Hash] parent_url, acceptance_token, spawn_mode,
        #   parent_peer_id, contract_version — same shape SpawnPlatformService builds
        # @param hostname [String, nil] VM hostname (default: derived from
        #   spawn_payload's parent_peer_id)
        # @param agent_url [String, nil] override the agent download URL.
        #   When nil, derived from spawn_payload's parent_url so the spawn
        #   pulls the agent FROM THE PARENT (always reachable, since the
        #   spawn was just told to enroll there). Hard-coding a separate
        #   download host invariably drifts out of sync with the parent
        #   topology and breaks federation-spawned children silently.
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
          @agent_url           = agent_url.presence || derived_agent_url
          @ssh_authorized_keys = Array(ssh_authorized_keys).compact.reject(&:empty?)
        end

        # Build the agent download URL from the spawn payload's parent_url.
        # parent_url is the platform the child is enrolling with, which is
        # by definition both reachable from the child AND the source of
        # truth for compatible agent builds.
        def derived_agent_url
          parent = @spawn_payload["parent_url"].to_s.sub(%r{/+\z}, "")
          parent.empty? ? DEFAULT_AGENT_PATH : "#{parent}#{DEFAULT_AGENT_PATH}"
        end

        # The platform base URL the agent uses for everything — enroll and
        # mTLS-authenticated node-api calls alike. With the single-entrypoint
        # optional-mTLS model, all traffic goes to the same :443 listener
        # (the agent presents its client cert once enrolled; the listener
        # verifies-if-given and forwards the CN). Trailing slashes trimmed so
        # the agent doesn't build a double-slash path.
        def base_platform_url
          @spawn_payload["parent_url"].to_s.sub(%r{/+\z}, "")
        end

        def render
          # Cloud-init expects the literal string `#cloud-config` on the
          # FIRST line (not the YAML header). YAML.dump emits `---` first,
          # so we concatenate manually.
          #
          # line_width: -1 disables YAML line-folding of long scalars
          # (e.g. SSH public keys which run ~90 chars). cloud-init's
          # parser theoretically handles folded plain scalars but in
          # practice some versions of cloud-init silently fail to parse
          # the ssh_authorized_keys value when it's folded across lines,
          # leaving the user with no installed key. Disable folding so
          # every key + write_files content stays on one line.
          "#cloud-config\n" + YAML.dump(payload, line_width: -1).sub(/\A---\n/, "")
        end

        private

        attr_reader :spawn_payload, :hostname, :agent_url, :ssh_authorized_keys

        # Packages cloud-init installs at first boot. Kept minimal — the
        # principle is that runtime tooling ships in modules (composed via
        # the agent reconciler), not via apt. The exceptions are tools
        # the AGENT itself needs in order to run before any module reconcile
        # has happened: wireguard-tools is required by Sdwan::Manager's
        # WG applier (shells out to `wg setconf`), and the agent starts
        # the SDWAN reconcile loop on first boot, BEFORE any module is
        # mounted that could ship the binary. Without this, SDWAN never
        # comes up on a fresh managed_child VM. Cloud-init's packages:
        # step runs BEFORE runcmd (which `systemctl enable --now`s the
        # agent), so wg will be on PATH by the time the agent first
        # invokes the WG applier.
        BASELINE_PACKAGES = %w[wireguard-tools].freeze

        def payload
          {
            "hostname"          => hostname,
            "manage_etc_hosts"  => true,
            # package_update + the packages: list together drive a one-time
            # apt update + apt install at first boot. Cloud-init does this
            # at the `cc_apt_configure` + `cc_package_update_upgrade_install`
            # stage, which runs before `cc_runcmd`.
            "package_update"    => true,
            "package_upgrade"   => false,
            "packages"          => BASELINE_PACKAGES,
            # operator is Powernode's standardized login user (UID 1000,
            # baked into agent etcidentity baseline). Cloud-init creates
            # it with NOPASSWD sudo at first boot so the operator has
            # a working escalation path before any module-declared
            # SudoersGrant has been applied — break-glass at the
            # cloud-init layer rather than depending on agent code.
            "users" => [
              {
                "name"                => "pnadmin",
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
          # Belt-and-suspenders: also write the operator's
          # authorized_keys directly. cloud-init's users: block already
          # passes ssh_authorized_keys through, but some images/cloud-init
          # versions silently drop folded-YAML scalars and leave the
          # account keyless. Writing via write_files (runs AFTER users:
          # creates /home/operator) guarantees the file lands.
          if ssh_authorized_keys.any?
            files << {
              "path"        => "/home/pnadmin/.ssh/authorized_keys",
              "permissions" => "0600",
              "owner"       => "pnadmin:pnadmin",
              "defer"       => true, # wait until pnadmin's home dir exists
              "content"     => ssh_authorized_keys.join("\n") + "\n"
            }
          end
          # Direct operator NOPASSWD sudoers grant. cloud-init's
          # users: sudo field SHOULD write /etc/sudoers.d/90-cloud-init-users
          # for us, but on this PVE-spawned VM topology that file
          # consistently doesn't materialize (likely the standard
          # ciuser + cicustom interaction skips the sudoers step).
          # The agent's break-glass file (when POWERNODE_OPERATOR_BREAK_GLASS=1
          # is set) covers this, but baking the same grant via cloud-init
          # makes operator sudoable from first boot, before the agent
          # has finished its first reconcile. Non-powernode- filename
          # so the agent's etcsudoers sweep never touches it.
          files << {
            "path"        => "/etc/sudoers.d/91-pnadmin-cloudinit",
            "permissions" => "0440",
            "owner"       => "root:root",
            "content"     => "pnadmin ALL=(ALL) NOPASSWD: ALL\n"
          }
          # Netplan override that ensures systemd-networkd sends the
          # configured hostname in DHCPREQUEST option 12. The stock
          # Ubuntu cloud image's auto-generated /etc/netplan/50-cloud-init.yaml
          # gets it right MOST of the time, but timing varies: networkd can
          # bring up eth0 + acquire a lease BEFORE cloud-init's
          # cc_set_hostname module fires, in which case the DHCPREQUEST
          # carries the BIOS-default "ubuntu" and the upstream dnsmasq's
          # DNS table gets a wrong entry. Higher numeric prefix overrides
          # the cloud-init-generated file (netplan reads in lexical order
          # and the later file wins per key). The runcmd below triggers a
          # lease renewal so the right hostname reaches the DHCP server
          # AFTER cloud-init has set /etc/hostname.
          files << {
            "path"        => "/etc/netplan/99-powernode-dhcp.yaml",
            "permissions" => "0644",
            "owner"       => "root:root",
            "content"     => netplan_override_content
          }
          files
        end

        def netplan_override_content
          # `send-hostname: true` is the default in networkd but stating it
          # explicitly survives any future cloud-init template changes that
          # might disable it. `use-hostname: false` keeps the boot-time
          # /etc/hostname authoritative — the upstream DHCP shouldn't
          # ever decide what our hostname is.
          #
          # Match by interface-name glob (`en*` + `eth*`) instead of
          # hard-coding `eth0`. Ubuntu cloud images use predictable names
          # like `enp0s18` / `ens18` for virtio-net NICs under q35; the
          # `eth0` name only appears on older biosdevname-disabled images.
          # Without the wildcard, netplan apply silently no-ops on PVE
          # spawns, the VM never DHCPs, and federation enrollment never
          # fires. Setting `dhcp-identifier: mac` makes the lease stable
          # across reboots (the default uses systemd-machine-id which
          # changes when the image is re-baked).
          <<~YAML
            network:
              version: 2
              ethernets:
                primary:
                  match:
                    name: "en*"
                  dhcp4: true
                  dhcp-identifier: mac
                  dhcp4-overrides:
                    send-hostname: true
                    use-hostname: false
                    hostname: #{hostname}
                primary-legacy:
                  match:
                    name: "eth*"
                  dhcp4: true
                  dhcp-identifier: mac
                  dhcp4-overrides:
                    send-hostname: true
                    use-hostname: false
                    hostname: #{hostname}
          YAML
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
            # POWERNODE_OPERATOR_BREAK_GLASS=1 writes /etc/sudoers.d/
            # powernode-operator-break-glass so the operator user can
            # sudo without going through a module-declared SudoersGrant.
            # Intended for dev/recovery loops on managed-child instances;
            # production deployments should rely on module SudoersGrant
            # rows and unset this flag.
            Environment=POWERNODE_OPERATOR_BREAK_GLASS=1
            # The long-running service performs mTLS-authenticated calls
            # against /api/v1/system/node_api/* — under the single-entrypoint
            # optional-mTLS model these share the same :443 listener as
            # enroll/bootstrap. The listener runs VerifyClientCertIfGiven, so
            # the pre-cert enroll handshake (bootstrap_token / acceptance_token
            # auth) succeeds without a cert, and once the agent holds a cert it
            # presents it on the same URL; Traefik verifies + forwards the CN.
            # One --platform-url for both phases — no separate mTLS port.
            ExecStart=/usr/local/bin/powernode-agent service --platform-url=#{base_platform_url} --pki-dir=/var/lib/powernode/pki
            Restart=on-failure
            RestartSec=10s
            # NOTE: previously had `ReadOnlyPaths=/sys/firmware/qemu_fw_cfg`
            # here to constrain the agent's view of fw-cfg. On PVE-spawned
            # VMs that path doesn't exist (PVE token-auth can't set the
            # `args` field needed to surface fw-cfg), so the directive
            # caused systemd to fail with code=226/NAMESPACE on every
            # restart. The fw-cfg path is now the file fallback at
            # /etc/powernode/federation-payload.json (read by the agent's
            # federation.LoadConfig); no sandboxing for that path is
            # needed here.

            [Install]
            WantedBy=multi-user.target
          UNIT
        end

        def runcmd
          [
            # Defense-in-depth operator SSH key install. The cloud-init
            # users: block SHOULD install ssh_authorized_keys, but when
            # PVE injects its own ciuser=operator metadata the merge
            # silently drops keys — operator gets created but with no
            # authorized_keys. Re-install directly so SSH works
            # regardless of cloud-init's user-module behavior.
            "id pnadmin >/dev/null 2>&1 || useradd -m -s /bin/bash pnadmin",
            "install -d -m 0700 -o pnadmin -g pnadmin /home/pnadmin/.ssh",
            *@ssh_authorized_keys.map { |k|
              # Append (not overwrite) so multiple keys accumulate; the
              # `grep -q` guard makes it idempotent across reboots/re-runs.
              %Q(grep -qxF '#{k}' /home/pnadmin/.ssh/authorized_keys 2>/dev/null || echo '#{k}' >> /home/pnadmin/.ssh/authorized_keys)
            },
            "chmod 600 /home/pnadmin/.ssh/authorized_keys",
            "chown pnadmin:pnadmin /home/pnadmin/.ssh/authorized_keys",
            # Apply the netplan override (write_files dropped it into
            # /etc/netplan/99-powernode-dhcp.yaml) and renew the DHCP
            # lease so the upstream DHCP server sees the cloud-init-set
            # hostname in option 12. Without this, the upstream dnsmasq's
            # DNS table holds whatever hostname was set when networkd
            # first leased — usually the BIOS-default "ubuntu" — and the
            # VM's friendly name never resolves.
            "netplan apply || true",
            # Reconfigure all networkd-managed interfaces — the actual
            # NIC name varies (eth0 on biosdevname-disabled images,
            # enp0s18/ens18 on Ubuntu cloud images). networkctl with no
            # iface arg reloads every interface, avoiding the silent
            # no-op `networkctl reconfigure eth0` produces when eth0
            # doesn't exist.
            "networkctl reload || true",
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
