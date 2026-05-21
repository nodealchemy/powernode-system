# frozen_string_literal: true

require_relative "proxmox/client"

module System
  module Providers
    # Proxmox VE cloud provider adapter.
    #
    # === Coverage ===
    # - Connection: authenticate? (token + ACL probe) / test_connection
    # - Lifecycle: create_instance (mode: :vm | :lxc) / start / stop /
    #   reboot / terminate / get / list
    # - Catalog: list_regions (= cluster nodes) / list_availability_zones (= 1 stub) /
    #   list_instance_types (preset flavors) / list_volume_types (storage pools)
    # - IP: DHCP-only — PVE has no public-IP allocation pool concept. The
    #   alloc/assoc/disassoc/release methods return no_op responses so callers
    #   that abstract across cloud providers don't have to special-case PVE.
    # - Volumes: PVE storage API for create/attach/detach/delete/get
    # - Images: import from URL via /storage/{storage}/download-url plus snapshot ops
    #
    # === Auth ===
    # API Token only. Token ID has the form `USER@REALM!TOKENNAME` (e.g.
    # `root@pam!powernode`), secret is a UUID, header is
    # `PVEAPIToken=<id>=<secret>`. We don't use ticket-based auth.
    #
    # === PVE API quirks baked in here ===
    # See `project_pve_api_learnings.md` for the full list. Recap of the most
    # impactful items the implementation works around:
    #   1. PVE returns `{"data": {}}` for missing ACLs (not 403). authenticate?
    #      probes /access/permissions and refuses to operate on an empty set.
    #   2. `import-from` requires `size=0` in the disk spec; final size is set
    #      by a separate /resize call after creation.
    #   3. `sshkeys` is double-URL-encoded: we URL-encode the keys ourselves,
    #      then Faraday's url_encoded middleware encodes again. PVE decodes
    #      twice on receive (HTTP layer + sshkeys validator).
    #   4. Cloud-init params (`ipconfig0`, `sshkeys`, `ciuser`) require a hard
    #      `reset` (not graceful `reboot`) to reload the cloudinit seed.
    #   5. PVE-managed snapshots require ALL VM disks to be in qcow2 format.
    #      raw on NFS doesn't snapshot. We default efidisk0 to qcow2.
    #   6. PVE 9 cloud-init defaults to `package_upgrade: true` on first boot.
    #      Callers can override via `cicustom` when they want minimal init.
    #
    # === Region semantics ===
    # PVE doesn't have "regions"; it has cluster nodes. We model each PVE node
    # as a region from the platform's perspective, since node placement matters
    # for VM scheduling and storage locality.
    class ProxmoxProvider < BaseProvider
      # ----------------------------------------------------------------
      # Status normalization tables
      # ----------------------------------------------------------------

      # Both qemu and lxc resources expose the same lifecycle states in PVE,
      # so a single map covers both.
      PVE_STATUS_MAP = {
        "running"   => "running",
        "stopped"   => "stopped",
        "paused"    => "stopped",
        "suspended" => "stopped",
        "shutdown"  => "stopping",
        "prelaunch" => "starting",
        "created"   => "pending"
      }.freeze

      # ----------------------------------------------------------------
      # Preset flavors
      #
      # PVE has no native "instance type" / "flavor" concept. We synthesize
      # presets so callers can pass `instance_type: "pve.vm.medium"` and have
      # cores/memory/storage resolved consistently.
      #
      # The `mode` field distinguishes KVM/QEMU VMs (`vm`) from LXC containers
      # (`lxc`). The provider routes create_instance to the right code path
      # based on this discriminator.
      # ----------------------------------------------------------------
      INSTANCE_TYPE_PRESETS = [
        { code: "pve.lxc.small",  vcpus: 2, memory_mb: 2_048,  storage_gb: 20,  mode: "lxc" },
        { code: "pve.lxc.medium", vcpus: 4, memory_mb: 4_096,  storage_gb: 40,  mode: "lxc" },
        { code: "pve.lxc.large",  vcpus: 8, memory_mb: 8_192,  storage_gb: 80,  mode: "lxc" },
        { code: "pve.vm.small",   vcpus: 2, memory_mb: 4_096,  storage_gb: 20,  mode: "vm"  },
        { code: "pve.vm.medium",  vcpus: 4, memory_mb: 8_192,  storage_gb: 80,  mode: "vm"  },
        { code: "pve.vm.large",   vcpus: 8, memory_mb: 16_384, storage_gb: 160, mode: "vm"  }
      ].freeze

      INSTANCE_TYPE_INDEX = INSTANCE_TYPE_PRESETS.each_with_object({}) { |p, h| h[p[:code]] = p }.freeze

      DEFAULT_NETWORK_BRIDGE   = "vmbr0"
      DEFAULT_MACHINE_TYPE     = "q35"
      DEFAULT_BIOS             = "ovmf"
      DEFAULT_SCSIHW           = "virtio-scsi-single"
      DEFAULT_CPU_TYPE         = "host"
      DEFAULT_OSTYPE           = "l26"
      DEFAULT_LXC_OSTYPE       = "ubuntu"

      # ----------------------------------------------------------------
      # Identity
      # ----------------------------------------------------------------

      def provider_type
        "proxmox"
      end

      # ----------------------------------------------------------------
      # Connection / health
      # ----------------------------------------------------------------

      # Lightweight auth probe. Returns true only if BOTH:
      #   - The token authenticates (so we can call /version)
      #   - The token has at least one ACL grant
      #
      # The second check is critical because PVE silently returns `{}` on
      # resource endpoints when ACL grants are missing — callers would
      # otherwise see "empty cluster" and fail mysteriously downstream.
      def authenticate?
        @last_authentication_error = nil
        c = build_client
        return missing_credentials_failure unless c

        version = c.get("/api2/json/version")
        unless version.is_a?(Hash) && version["version"]
          @last_authentication_error = "PVE /version returned unexpected payload"
          return false
        end

        unless c.has_any_grants?
          @last_authentication_error =
            "Token authenticates but has no ACL grants. " \
            "Add an 'API Token Permission' on path / with role PVEVMAdmin " \
            "(or higher), or disable Privilege Separation on the token."
          return false
        end

        true
      rescue Proxmox::Client::AuthError => e
        @last_authentication_error = "PVE auth failed: #{e.message}"
        false
      rescue Proxmox::Client::Error => e
        @last_authentication_error = "PVE connection failed: #{e.message}"
        false
      end

      # Richer health check used by Phase 2 onboarding UIs. Returns a
      # structured Hash with cluster name, node count, and PVE version.
      def test_connection
        c = build_client
        return { success: false, error: "Missing PVE credentials" } unless c

        version = c.get("/api2/json/version")
        nodes = c.get("/api2/json/nodes") || []

        {
          success: true,
          message: "PVE connection healthy",
          pve_version: version["version"],
          pve_release: version["release"],
          node_count: nodes.size,
          nodes: nodes.map { |n| { name: n["node"], status: n["status"] } }
        }
      rescue StandardError => e
        { success: false, error: "PVE test_connection failed: #{e.message}" }
      end

      def get_metadata
        {
          provider: "proxmox",
          region: region&.region_code,
          features: %w[
            vm_lifecycle lxc_lifecycle snapshots template_clone
            cloud_init dhcp_only storage_api
          ]
        }
      end

      # ----------------------------------------------------------------
      # Instance lifecycle
      # ----------------------------------------------------------------

      # Create a VM or LXC. The discriminator is the `mode` field on the
      # instance_type preset.
      #
      # @param params [Hash]
      # @option params [String] :name (required)            VM / LXC hostname
      # @option params [String] :instance_type (required)   preset code e.g. "pve.vm.medium"
      # @option params [String] :image_id (required)        source image:
      #                                                       - VM: "<storage>:import/<file>.qcow2"
      #                                                       - LXC: "<storage>:vztmpl/<file>.tar.zst"
      # @option params [String] :node                       target PVE node (default: first online)
      # @option params [Integer] :vmid                      explicit VMID (default: cluster/nextid)
      # @option params [String] :storage                    target storage pool for disks
      # @option params [String] :network_bridge             default "vmbr0"
      # @option params [String] :ip_config                  default "ip=dhcp"
      # @option params [Array<String>] :ssh_keys            public keys to install
      # @option params [String] :user_data                  raw cloud-init user-data (VM only)
      # @option params [Boolean] :protection                set protection=1 after create (default true for VMs)
      # @option params [Hash] :extra                        passthrough params for advanced callers
      def create_instance(params)
        log_operation("create_instance", params: params.except(:user_data, :ssh_keys))

        preset = resolve_preset!(params[:instance_type])
        mode = preset[:mode]

        if mode == "vm"
          create_vm_instance(params, preset: preset)
        elsif mode == "lxc"
          create_lxc_instance(params, preset: preset)
        else
          raise ProviderError, "Unknown PVE mode: #{mode.inspect}"
        end
      rescue Proxmox::Client::AuthError => e
        raise AuthenticationError, e.message
      rescue Proxmox::Client::NotFoundError => e
        raise ResourceNotFoundError, e.message
      rescue Proxmox::Client::RateLimitError => e
        raise RateLimitError, e.message
      rescue Proxmox::Client::TaskFailedError => e
        build_error_response("PVE task failed: #{e.message} — log tail: #{e.log_tail.last(3).join(' / ')}",
                             code: e.exit_status)
      rescue Proxmox::Client::Error => e
        build_error_response("PVE error: #{e.message}")
      end

      def start_instance(instance_id)
        log_operation("start_instance", instance_id: instance_id)
        node, kind, vmid = parse_instance_id!(instance_id)
        c = require_client!
        upid = c.post("/api2/json/nodes/#{node}/#{kind}/#{vmid}/status/start")
        c.wait_task(node: node, upid: upid)
        sync_status(instance_id)
      rescue Proxmox::Client::NotFoundError => e
        raise ResourceNotFoundError, e.message
      rescue Proxmox::Client::Error => e
        build_error_response("PVE start failed: #{e.message}")
      end

      def stop_instance(instance_id, force: false)
        log_operation("stop_instance", instance_id: instance_id, force: force)
        node, kind, vmid = parse_instance_id!(instance_id)
        c = require_client!
        action = force ? "stop" : "shutdown"
        upid = c.post("/api2/json/nodes/#{node}/#{kind}/#{vmid}/status/#{action}")
        c.wait_task(node: node, upid: upid)
        sync_status(instance_id)
      rescue Proxmox::Client::NotFoundError => e
        raise ResourceNotFoundError, e.message
      rescue Proxmox::Client::Error => e
        build_error_response("PVE stop failed: #{e.message}")
      end

      def reboot_instance(instance_id)
        log_operation("reboot_instance", instance_id: instance_id)
        node, kind, vmid = parse_instance_id!(instance_id)
        c = require_client!
        # NOTE: qmreboot is graceful; if the caller really needs to discard
        # cloud-init seed state (e.g., after sshkeys change), use stop+start
        # instead. Documented in project_pve_api_learnings.md item #5.
        upid = c.post("/api2/json/nodes/#{node}/#{kind}/#{vmid}/status/reboot")
        c.wait_task(node: node, upid: upid)
        sync_status(instance_id)
      rescue Proxmox::Client::Error => e
        build_error_response("PVE reboot failed: #{e.message}")
      end

      def terminate_instance(instance_id)
        log_operation("terminate_instance", instance_id: instance_id)
        node, kind, vmid = parse_instance_id!(instance_id)
        c = require_client!

        # Best-effort graceful stop first; ignore failures (the guest may
        # already be off, or it may refuse to shut down). Then destroy.
        begin
          stop_upid = c.post("/api2/json/nodes/#{node}/#{kind}/#{vmid}/status/stop")
          c.wait_task(node: node, upid: stop_upid, timeout: 30)
        rescue Proxmox::Client::Error
          nil
        end

        # `purge=1` removes the VM's references from job configs (backup, replication);
        # `destroy-unreferenced-disks=1` cleans up any storage volumes attached.
        delete_upid = c.delete("/api2/json/nodes/#{node}/#{kind}/#{vmid}",
                               { "purge" => 1, "destroy-unreferenced-disks" => 1 })
        c.wait_task(node: node, upid: delete_upid)

        build_instance_response(cloud_id: instance_id, status: STATUSES[:terminated])
      rescue Proxmox::Client::NotFoundError
        # Already gone — treat as success
        build_instance_response(cloud_id: instance_id, status: STATUSES[:terminated])
      rescue Proxmox::Client::Error => e
        build_error_response("PVE terminate failed: #{e.message}")
      end

      def get_instance(instance_id)
        log_operation("get_instance", instance_id: instance_id)
        sync_status(instance_id)
      rescue Proxmox::Client::NotFoundError => e
        raise ResourceNotFoundError, e.message
      rescue Proxmox::Client::Error => e
        build_error_response("PVE get_instance failed: #{e.message}")
      end

      def list_instances(filters = {})
        log_operation("list_instances", filters: filters)
        c = require_client!
        resources = c.get("/api2/json/cluster/resources", { "type" => filters[:type] || nil }.compact)
        instances = (resources || []).select { |r| %w[qemu lxc].include?(r["type"]) }

        if filters[:status]
          want = filters[:status].to_s
          instances = instances.select { |i| PVE_STATUS_MAP[i["status"].to_s] == want }
        end

        {
          success: true,
          instances: instances.map { |i| serialize_resource_summary(i) },
          page_count: 1,
          truncated: false
        }
      rescue Proxmox::Client::Error => e
        build_error_response("PVE list_instances failed: #{e.message}")
      end

      # ----------------------------------------------------------------
      # IP allocations — PVE has no public-IP pool. Networks are bridge
      # attachments; addresses come from DHCP at the LAN layer. The IP
      # methods exist for interface compatibility with cloud providers.
      # ----------------------------------------------------------------

      def allocate_ip
        { success: false, error: "Proxmox does not support IP allocations; use DHCP on the bridge" }
      end

      def associate_ip(_instance_id, allocation_id: nil)
        { success: false, error: "Proxmox does not support IP associations; use ipconfig0 / net0 settings on the instance" }
      end

      def disassociate_ip(_association_id)
        { success: false, error: "Proxmox does not support IP associations" }
      end

      def release_ip(_allocation_id)
        { success: false, error: "Proxmox does not support IP allocations" }
      end

      # ----------------------------------------------------------------
      # Volumes
      # ----------------------------------------------------------------

      # @param params [Hash]
      # @option params [Integer] :size_gb (required)
      # @option params [String] :node (required)
      # @option params [String] :storage (required)
      # @option params [String] :format ("qcow2" by default — required for snapshots)
      # @option params [String] :name (default: timestamp-based)
      def create_volume(params)
        log_operation("create_volume", params: params)
        c = require_client!
        node = params[:node] || params[:availability_zone] || first_online_node!(c)
        storage = params[:storage] || first_shared_storage_with_content!(c, node: node, content: "images")
        format = params[:format] || "qcow2"
        vmid = params[:vmid] || allocate_next_vmid!(c)
        filename = params[:name] || "vol-#{vmid}-#{Time.now.to_i}"
        size_param = "#{params.fetch(:size_gb)}G"

        body = {
          "vmid" => vmid,
          "filename" => "#{filename}.#{format}",
          "size" => size_param,
          "format" => format
        }
        result = c.post("/api2/json/nodes/#{node}/storage/#{storage}/content", body)
        volid = result.is_a?(String) ? result : result.to_s

        {
          success: true,
          volume_id: volid,
          size_gb: params[:size_gb],
          format: format
        }
      rescue Proxmox::Client::Error => e
        build_error_response("PVE create_volume failed: #{e.message}")
      end

      def attach_volume(volume_id, instance_id, device: nil)
        log_operation("attach_volume", volume_id: volume_id, instance_id: instance_id, device: device)
        node, kind, vmid = parse_instance_id!(instance_id)
        c = require_client!
        target_device = device || next_free_disk_slot!(c, node: node, kind: kind, vmid: vmid)
        # qcow2 volumes attach with iothread + discard for best performance
        spec = "#{volume_id},iothread=1,discard=on"
        c.put("/api2/json/nodes/#{node}/#{kind}/#{vmid}/config", { target_device => spec })
        { success: true, device: target_device, instance_id: instance_id }
      rescue Proxmox::Client::Error => e
        build_error_response("PVE attach_volume failed: #{e.message}")
      end

      def detach_volume(volume_id, force: false)
        log_operation("detach_volume", volume_id: volume_id, force: force)
        # PVE doesn't have a generic "detach by volume ID" endpoint — you have
        # to know which instance + slot the disk is at. The caller is
        # expected to pass instance context via the volume_id locator
        # ("node/kind/vmid/slot=volume") for full detach support. For now
        # we report this as unsupported and let the caller use update_disk
        # against the instance config directly.
        { success: false, error: "Use PUT /qemu|lxc/{vmid}/config with --delete <slot> to detach a specific disk" }
      end

      def delete_volume(volume_id)
        log_operation("delete_volume", volume_id: volume_id)
        c = require_client!
        # volume_id format: "<storage>:<path>" — we need to figure out which node
        # to call. Storage-with-shared=1 is reachable from any node, so use
        # the first online node.
        node = first_online_node!(c)
        c.delete("/api2/json/nodes/#{node}/storage/#{encode_volid(volume_id)}/content")
        { success: true, volume_id: volume_id }
      rescue Proxmox::Client::NotFoundError
        { success: true, volume_id: volume_id, message: "already deleted" }
      rescue Proxmox::Client::Error => e
        build_error_response("PVE delete_volume failed: #{e.message}")
      end

      def get_volume(volume_id)
        log_operation("get_volume", volume_id: volume_id)
        c = require_client!
        node = first_online_node!(c)
        info = c.get("/api2/json/nodes/#{node}/storage/#{encode_volid(volume_id)}/content")
        { success: true, volume_id: volume_id, details: info }
      rescue Proxmox::Client::NotFoundError
        raise ResourceNotFoundError, "Volume #{volume_id} not found"
      rescue Proxmox::Client::Error => e
        build_error_response("PVE get_volume failed: #{e.message}")
      end

      # ----------------------------------------------------------------
      # Images / templates
      # ----------------------------------------------------------------

      # Snapshot the running instance as a "template" — PVE has both
      # snapshot-based templates and convert-to-template VMs. We use
      # snapshots here for simplicity and reversibility.
      def create_image(instance_id, name:, description: nil)
        log_operation("create_image", instance_id: instance_id, name: name)
        node, kind, vmid = parse_instance_id!(instance_id)
        c = require_client!
        snapname = sanitize_snapname(name)
        upid = c.post("/api2/json/nodes/#{node}/#{kind}/#{vmid}/snapshot",
                      { "snapname" => snapname, "description" => description.to_s })
        c.wait_task(node: node, upid: upid)
        { success: true, image_id: "#{node}/#{kind}/#{vmid}@#{snapname}" }
      rescue Proxmox::Client::Error => e
        build_error_response("PVE create_image (snapshot) failed: #{e.message}")
      end

      def get_image(image_id)
        log_operation("get_image", image_id: image_id)
        c = require_client!
        node, kind, vmid, snapname = parse_image_id!(image_id)
        snaps = c.get("/api2/json/nodes/#{node}/#{kind}/#{vmid}/snapshot")
        snap = (snaps || []).find { |s| s["name"] == snapname }
        raise ResourceNotFoundError, "Image #{image_id} not found" unless snap

        { success: true, image_id: image_id, details: snap }
      rescue Proxmox::Client::Error => e
        build_error_response("PVE get_image failed: #{e.message}")
      end

      def delete_image(image_id)
        log_operation("delete_image", image_id: image_id)
        c = require_client!
        node, kind, vmid, snapname = parse_image_id!(image_id)
        upid = c.delete("/api2/json/nodes/#{node}/#{kind}/#{vmid}/snapshot/#{snapname}")
        c.wait_task(node: node, upid: upid)
        { success: true, image_id: image_id }
      rescue Proxmox::Client::NotFoundError
        { success: true, image_id: image_id, message: "already deleted" }
      rescue Proxmox::Client::Error => e
        build_error_response("PVE delete_image failed: #{e.message}")
      end

      # ----------------------------------------------------------------
      # Catalog sync
      # ----------------------------------------------------------------

      # PVE has cluster nodes, not regions. We expose each node as a region
      # so the platform's NodeInstance placement logic can target a specific
      # PVE node for VM scheduling.
      def list_regions
        c = require_client!
        (c.get("/api2/json/nodes") || []).map do |n|
          {
            cloud_id: n["node"],
            name: n["node"],
            description: "PVE node #{n['node']}",
            status: n["status"],
            cpus: n["maxcpu"],
            ram_total: n["maxmem"],
            disk_total: n["maxdisk"]
          }
        end
      end

      # PVE has no AZ concept under a node. Return a single stub AZ per
      # node so the catalog table is populated consistently with other
      # providers.
      def list_availability_zones(region_code)
        [{
          cloud_id: "#{region_code}-zone-a",
          name: "#{region_code}/a",
          status: "available"
        }]
      end

      # Return the synthesized preset table. Each preset maps to cores +
      # memory + disk size choices when create_instance is called.
      def list_instance_types(_region_code = nil)
        INSTANCE_TYPE_PRESETS.map do |p|
          {
            cloud_id: p[:code],
            name: p[:code],
            vcpus: p[:vcpus],
            memory_mb: p[:memory_mb],
            storage_gb: p[:storage_gb],
            metadata: { "mode" => p[:mode] }
          }
        end
      end

      # PVE storage pools, viewed as "volume types". We surface every pool
      # the token can see, annotated with shared status and supported
      # content types. Callers pick a pool when creating volumes.
      def list_volume_types(region_code = nil)
        c = require_client!
        node = region_code || first_online_node!(c)
        (c.get("/api2/json/nodes/#{node}/storage") || []).map do |s|
          {
            cloud_id: s["storage"],
            name: s["storage"],
            plugin_type: s["plugintype"] || s["type"],
            shared: s["shared"] == 1,
            content_types: (s["content"] || "").split(","),
            total_bytes: s["total"],
            avail_bytes: s["avail"]
          }
        end
      end

      # ----------------------------------------------------------------
      # protected: status normalization (defined on BaseProvider as protected)
      # ----------------------------------------------------------------

      protected

      def normalize_status(pve_status)
        PVE_STATUS_MAP.fetch(pve_status.to_s.downcase, STATUSES[:unknown])
      end

      # ----------------------------------------------------------------
      # private: implementation helpers
      # ----------------------------------------------------------------

      private

      # ============================================================
      # VM creation
      # ============================================================

      def create_vm_instance(params, preset:)
        c = require_client!
        node = params[:node] || first_online_node!(c)
        vmid = params[:vmid] || allocate_next_vmid!(c)
        storage = params[:storage] || first_shared_storage_with_content!(c, node: node, content: "images")
        bridge = params[:network_bridge] || DEFAULT_NETWORK_BRIDGE
        ip_config = params[:ip_config] || "ip=dhcp"
        image_volid = params.fetch(:image_id)

        # Build the qemu create body. The scsi0 disk uses size=0 with
        # `import-from` (PVE quirk #3: import requires zero target size).
        # We resize after creation.
        body = {
          "vmid"     => vmid,
          "name"     => params.fetch(:name),
          "cores"    => preset[:vcpus],
          "sockets"  => 1,
          "cpu"      => params[:cpu] || DEFAULT_CPU_TYPE,
          "memory"   => preset[:memory_mb],
          "balloon"  => 0,
          "machine"  => params[:machine] || DEFAULT_MACHINE_TYPE,
          "bios"     => params[:bios]    || DEFAULT_BIOS,
          # efidisk0 in qcow2 — PVE quirk #5: snapshots require all-qcow2 disks
          "efidisk0" => "#{storage}:0,efitype=4m,format=qcow2",
          "scsihw"   => DEFAULT_SCSIHW,
          "scsi0"    => "#{storage}:0,import-from=#{image_volid},iothread=1,discard=on",
          "net0"     => "virtio,bridge=#{bridge}",
          "ostype"   => params[:ostype] || DEFAULT_OSTYPE,
          "agent"    => "enabled=1",
          "boot"     => "order=scsi0",
          "onboot"   => params.fetch(:onboot, 1),
          "ide2"     => "#{storage}:cloudinit,media=cdrom",
          "serial0"  => "socket",
          "vga"      => "serial0",
          "ciuser"   => params[:ci_user] || "ubuntu",
          "ipconfig0" => ip_config
        }
        body["nameserver"]   = params[:nameserver]   if params[:nameserver]
        body["searchdomain"] = params[:searchdomain] if params[:searchdomain]
        body["cipassword"]   = params[:ci_password]  if params[:ci_password]

        # cicustom: arbitrary cloud-init user-data via snippets. PVE has no
        # REST API for snippet upload — they must reach the storage's
        # snippets/ directory through the filesystem. We assume the operator
        # has mounted a snippets-enabled storage (typically NFS shared
        # across the cluster) at `:snippets_local_path` and configured the
        # matching PVE storage name as `:snippets_storage`. Defaults assume
        # the Powernode-platform-on-ops shape: dsm-data NFS at
        # /mnt/pve-data/snippets. Sub-volume IDs in cicustom are relative
        # to the storage root, hence `snippets/<filename>`.
        if params[:user_data].present? || params[:meta_data].present?
          snippets_storage = params[:snippets_storage] ||
                             connection&.config&.dig("snippets_storage") ||
                             "dsm-data"
          snippets_local   = params[:snippets_local_path] ||
                             connection&.config&.dig("snippets_local_path") ||
                             "/mnt/pve-data/snippets"
          cicustom_parts = []
          if params[:user_data].present?
            user_path = File.join(snippets_local, "#{vmid}-user.yml")
            File.write(user_path, params[:user_data], mode: "w", perm: 0o644)
            cicustom_parts << "user=#{snippets_storage}:snippets/#{vmid}-user.yml"
          end
          if params[:meta_data].present?
            meta_path = File.join(snippets_local, "#{vmid}-meta.yml")
            File.write(meta_path, params[:meta_data], mode: "w", perm: 0o644)
            cicustom_parts << "meta=#{snippets_storage}:snippets/#{vmid}-meta.yml"
          end
          if params[:network_config].present?
            net_path = File.join(snippets_local, "#{vmid}-net.yml")
            File.write(net_path, params[:network_config], mode: "w", perm: 0o644)
            cicustom_parts << "network=#{snippets_storage}:snippets/#{vmid}-net.yml"
          end
          body["cicustom"] = cicustom_parts.join(",") unless cicustom_parts.empty?
        end

        # fw_cfg_entries: virtio-fw-cfg seed entries (the LocalQemu CloudSeed
        # pattern, mirrored for PVE). The Go agent at
        # extensions/system/agent/internal/federation/config.go reads each
        # entry from /sys/firmware/qemu_fw_cfg/by_name/opt/com.powernode/<key>.
        #
        # PVE doesn't expose a structured fw-cfg config field — we go through
        # the `args` escape-hatch, passing `-fw_cfg name=...,file=<path>` per
        # entry. The files MUST live on a PVE-side filesystem path; we stage
        # them on the same NFS-shared snippets storage used by cicustom so a
        # single mount on ops covers both seeding mechanisms. The PVE-side
        # mount path follows the `/mnt/pve/<storage>/` convention.
        # Derive fw_cfg entries from spawn_payload when the provisioner
        # passed one (Federation::SpawnProvisioner). Direct
        # params[:fw_cfg_entries] takes precedence — operator can
        # extend/override the default federation set.
        fw_cfg = params[:fw_cfg_entries].is_a?(Hash) ? params[:fw_cfg_entries].dup : {}
        spawn_payload = params.dig(:options, :spawn_payload) || params[:spawn_payload]
        if spawn_payload.is_a?(Hash) && spawn_payload["parent_url"].to_s.length > 0
          fw_cfg["opt/com.powernode/parent_url"]       ||= spawn_payload["parent_url"].to_s
          fw_cfg["opt/com.powernode/acceptance_token"] ||= spawn_payload["acceptance_token"].to_s
          fw_cfg["opt/com.powernode/spawn_mode"]       ||= spawn_payload["spawn_mode"].to_s
          fw_cfg["opt/com.powernode/parent_peer_id"]   ||= spawn_payload["parent_peer_id"].to_s
          fw_cfg["opt/com.powernode/contract_version"] ||= (spawn_payload["contract_version"] || "v1").to_s
        end

        if fw_cfg.any?
          snippets_storage = params[:snippets_storage] ||
                             connection&.config&.dig("snippets_storage") ||
                             "dsm-data"
          snippets_local   = params[:snippets_local_path] ||
                             connection&.config&.dig("snippets_local_path") ||
                             "/mnt/pve-data/snippets"
          pve_side_root    = "/mnt/pve/#{snippets_storage}/snippets"

          fwcfg_subdir_ops = File.join(snippets_local, "#{vmid}-fwcfg")
          fwcfg_subdir_pve = "#{pve_side_root}/#{vmid}-fwcfg"
          FileUtils.mkdir_p(fwcfg_subdir_ops, mode: 0o755)

          fw_args = []
          fw_cfg.each do |key, value|
            # Sanitize key for filename — "opt/com.powernode/parent_url" →
            # "opt_com_powernode_parent_url"
            safe = key.to_s.gsub(/[^A-Za-z0-9_.\-]/, "_")
            entry_path_ops = File.join(fwcfg_subdir_ops, safe)
            entry_path_pve = "#{fwcfg_subdir_pve}/#{safe}"
            File.write(entry_path_ops, value.to_s, mode: "w", perm: 0o644)
            fw_args << "-fw_cfg name=#{key},file=#{entry_path_pve}"
          end

          existing = body["args"].to_s
          body["args"] = [existing, fw_args.join(" ")].reject(&:empty?).join(" ")
        end

        create_upid = c.post("/api2/json/nodes/#{node}/qemu", body)
        c.wait_task(node: node, upid: create_upid)

        # Resize the imported disk to the final target size.
        # (PVE quirk #3 cont'd: import sets disk to source size; resize after.)
        target_size_gb = params[:storage_gb] || preset[:storage_gb]
        resize_upid = c.put("/api2/json/nodes/#{node}/qemu/#{vmid}/resize",
                            { "disk" => "scsi0", "size" => "#{target_size_gb}G" })
        # resize may return a UPID or empty; wait if UPID-shaped
        c.wait_task(node: node, upid: resize_upid) if upid_like?(resize_upid)

        # Install SSH keys via separate config update (PVE quirk #4:
        # sshkeys is double-URL-encoded; sending via the same body as
        # other fields with --data-urlencode doesn't work).
        ssh_keys = Array(params[:ssh_keys]).compact.reject(&:empty?)
        if ssh_keys.any?
          set_ssh_keys!(c, node: node, kind: "qemu", vmid: vmid, ssh_keys: ssh_keys)
        end

        # Set protection (default: ON for VMs since these are durable resources)
        if params.fetch(:protection, true)
          c.put("/api2/json/nodes/#{node}/qemu/#{vmid}/config", { "protection" => 1 })
        end

        instance_id = "#{node}/qemu/#{vmid}"

        # Optionally start now (default: false — caller does start_instance
        # after any post-create config is applied)
        if params[:start]
          start_instance(instance_id)
        else
          build_instance_response(cloud_id: instance_id, status: STATUSES[:stopped])
        end
      end

      # ============================================================
      # LXC creation
      # ============================================================

      def create_lxc_instance(params, preset:)
        c = require_client!
        node = params[:node] || first_online_node!(c)
        vmid = params[:vmid] || allocate_next_vmid!(c)
        storage = params[:storage] || first_shared_storage_with_content!(c, node: node, content: "rootdir")
        bridge = params[:network_bridge] || DEFAULT_NETWORK_BRIDGE
        ip_config = params[:ip_config] || "ip=dhcp"
        ostemplate = params.fetch(:image_id)

        # LXC params have a different shape than qemu:
        #   - hostname instead of name
        #   - ostemplate instead of import-from
        #   - rootfs instead of scsi0
        #   - net0 uses a different inline DSL
        net0_spec = "name=eth0,bridge=#{bridge},#{ip_config}"

        body = {
          "vmid"         => vmid,
          "hostname"     => params.fetch(:name),
          "ostemplate"   => ostemplate,
          "storage"      => storage,
          "rootfs"       => "#{storage}:#{params[:storage_gb] || preset[:storage_gb]}",
          "cores"        => preset[:vcpus],
          "memory"       => preset[:memory_mb],
          "swap"         => params[:swap] || (preset[:memory_mb] / 2),
          "net0"         => net0_spec,
          "ostype"       => params[:ostype] || DEFAULT_LXC_OSTYPE,
          "unprivileged" => params.fetch(:unprivileged, 1),
          "onboot"       => params.fetch(:onboot, 1),
          "features"     => params[:features] || "nesting=1"
        }
        body["nameserver"]   = params[:nameserver]   if params[:nameserver]
        body["searchdomain"] = params[:searchdomain] if params[:searchdomain]
        body["password"]     = params[:lxc_password] if params[:lxc_password]

        # SSH keys for LXC use a different param name (`ssh-public-keys`)
        # and are sent at create time, not via subsequent config PUT.
        # The double-URL-encoding pattern still applies.
        ssh_keys = Array(params[:ssh_keys]).compact.reject(&:empty?)
        if ssh_keys.any?
          body["ssh-public-keys"] = url_encode_keys(ssh_keys)
        end

        create_upid = c.post("/api2/json/nodes/#{node}/lxc", body)
        c.wait_task(node: node, upid: create_upid)

        # Set protection
        if params.fetch(:protection, true)
          c.put("/api2/json/nodes/#{node}/lxc/#{vmid}/config", { "protection" => 1 })
        end

        instance_id = "#{node}/lxc/#{vmid}"
        if params[:start]
          start_instance(instance_id)
        else
          build_instance_response(cloud_id: instance_id, status: STATUSES[:stopped])
        end
      end

      # ============================================================
      # Status sync (common for VM + LXC)
      # ============================================================

      def sync_status(instance_id)
        c = require_client!
        node, kind, vmid = parse_instance_id!(instance_id)
        current = c.get("/api2/json/nodes/#{node}/#{kind}/#{vmid}/status/current") || {}
        agent_iface = nil
        if kind == "qemu" && current["agent"].to_i == 1 && current["status"] == "running"
          # Best-effort IP from guest agent — soft-fail if agent isn't up yet
          begin
            ifaces = c.get("/api2/json/nodes/#{node}/qemu/#{vmid}/agent/network-get-interfaces")
            agent_iface = first_non_loopback_ipv4(ifaces)
          rescue Proxmox::Client::Error
            # guest agent not responding yet — that's OK during initial boot
          end
        end

        build_instance_response(
          cloud_id: instance_id,
          status: normalize_status(current["status"]),
          private_ip: agent_iface || extract_lxc_ip(current),
          node: node,
          kind: kind,
          vmid: vmid,
          uptime: current["uptime"],
          qmpstatus: current["qmpstatus"]
        )
      end

      # ============================================================
      # SSH key handling (PVE quirk #4: double-URL-encoded)
      # ============================================================

      def set_ssh_keys!(c, node:, kind:, vmid:, ssh_keys:)
        encoded = url_encode_keys(ssh_keys)
        # We send a single key under `sshkeys` (already URL-encoded by us);
        # Faraday's url_encoded middleware will encode again. PVE decodes
        # twice on receive.
        c.put("/api2/json/nodes/#{node}/#{kind}/#{vmid}/config", { "sshkeys" => encoded })
      end

      # URL-encodes keys joined by newline for PVE's sshkeys / ssh-public-keys param.
      # PVE's sshkeys validator wants URI-style encoding (%20 for space, not "+").
      # CGI.escape uses form-encoding (+ for space), which PVE's validator rejects
      # as "invalid urlencoded string" / "SSH public key validation error".
      # So we use a manual RFC 3986-style encoder that produces %20 for space.
      # Faraday's url_encoded middleware then wraps the body in form encoding,
      # so on the wire we get %2520 (the wrapped %20). PVE form-decodes once
      # (→ %20), then sshkeys validator URI-decodes (→ space). Plain keys
      # arrive intact. (project_pve_api_learnings.md item #4.)
      def url_encode_keys(keys)
        plain = keys.join("\n") + "\n"
        # RFC 3986 unreserved: A-Za-z0-9-._~. Everything else → %XX (uppercase hex).
        plain.gsub(/[^A-Za-z0-9\-._~]/) { |c| "%%%02X" % c.ord }
      end

      # ============================================================
      # Identifier parsing
      #
      # We use a compound instance_id `<node>/<kind>/<vmid>` as the cloud_id
      # returned from create_instance. This carries enough context that we
      # don't need to query the cluster every time to find which node hosts
      # a given VM/LXC.
      # ============================================================

      def parse_instance_id!(instance_id)
        node, kind, vmid = instance_id.to_s.split("/", 3)
        raise ResourceNotFoundError, "Malformed instance_id #{instance_id.inspect}; expected <node>/<kind>/<vmid>" if node.nil? || kind.nil? || vmid.nil?
        raise ResourceNotFoundError, "Unknown kind #{kind.inspect} in #{instance_id.inspect}" unless %w[qemu lxc].include?(kind)
        [node, kind, vmid]
      end

      def parse_image_id!(image_id)
        m = image_id.to_s.match(%r{\A([^/]+)/(qemu|lxc)/(\d+)@(.+)\z})
        raise ResourceNotFoundError, "Malformed image_id #{image_id.inspect}; expected <node>/<kind>/<vmid>@<snapname>" unless m
        [m[1], m[2], m[3], m[4]]
      end

      # ============================================================
      # Cluster discovery helpers
      # ============================================================

      def first_online_node!(c)
        nodes = c.get("/api2/json/nodes") || []
        node = nodes.find { |n| n["status"] == "online" }
        raise ProviderError, "No online PVE nodes available" unless node
        node["node"]
      end

      def allocate_next_vmid!(c)
        result = c.get("/api2/json/cluster/nextid")
        Integer(result.to_s)
      end

      def first_shared_storage_with_content!(c, node:, content:)
        storages = c.get("/api2/json/nodes/#{node}/storage") || []
        match = storages.find do |s|
          s["active"] == 1 &&
            (s["content"] || "").split(",").include?(content) &&
            (s["shared"] == 1 || storages.length == 1)
        end
        match ||= storages.find { |s| s["active"] == 1 && (s["content"] || "").split(",").include?(content) }
        raise ProviderError, "No storage on node #{node} supports content type #{content}" unless match
        match["storage"]
      end

      def next_free_disk_slot!(c, node:, kind:, vmid:)
        config = c.get("/api2/json/nodes/#{node}/#{kind}/#{vmid}/config") || {}
        prefix = kind == "qemu" ? "scsi" : "mp"
        (0..15).each do |i|
          slot = "#{prefix}#{i}"
          return slot unless config.key?(slot)
        end
        raise ProviderError, "No free disk slot on #{kind}/#{vmid}"
      end

      # ============================================================
      # Misc
      # ============================================================

      def serialize_resource_summary(r)
        {
          cloud_instance_id: "#{r['node']}/#{r['type']}/#{r['vmid']}",
          name: r["name"],
          status: normalize_status(r["status"]),
          cpus: r["maxcpu"],
          memory_bytes: r["maxmem"],
          disk_bytes: r["maxdisk"],
          uptime: r["uptime"],
          node: r["node"],
          kind: r["type"],
          vmid: r["vmid"]
        }
      end

      def extract_lxc_ip(current)
        # LXC reports the assigned IPs in current["ha"]... actually no, only
        # via the guest agent or the network-get-interfaces equivalent. For
        # now, return nil if we can't determine; caller can fall back to
        # ARP / DNS.
        nil
      end

      def first_non_loopback_ipv4(ifaces_payload)
        return nil unless ifaces_payload.is_a?(Hash)
        results = ifaces_payload["result"]
        return nil unless results.is_a?(Array)
        results.each do |iface|
          next if iface["name"] == "lo"
          addrs = iface["ip-addresses"]
          next unless addrs.is_a?(Array)
          v4 = addrs.find { |a| a["ip-address-type"] == "ipv4" && !a["ip-address"].to_s.start_with?("127.") }
          return v4["ip-address"] if v4
        end
        nil
      end

      def upid_like?(value)
        value.is_a?(String) && value.start_with?("UPID:")
      end

      def sanitize_snapname(name)
        name.to_s.gsub(/[^A-Za-z0-9_-]/, "").slice(0, 40).presence || "snap-#{Time.now.to_i}"
      end

      def encode_volid(volid)
        CGI.escape(volid.to_s)
      end

      def resolve_preset!(code)
        preset = INSTANCE_TYPE_INDEX[code.to_s]
        raise ProviderError, "Unknown PVE instance type #{code.inspect}; valid: #{INSTANCE_TYPE_INDEX.keys.join(', ')}" unless preset
        preset
      end

      # ============================================================
      # Credential resolution + client construction
      # ============================================================

      def require_client!
        c = build_client
        raise AuthenticationError, "Proxmox credentials missing or invalid" unless c
        c
      end

      def build_client
        endpoint = pve_credential("endpoint_url", "endpoint")
        token_id = pve_credential("access_key", "token_id")
        token_secret = pve_credential("secret_key", "token_secret")
        verify_ssl_raw = pve_credential("verify_ssl", "verify_ssl", default: "true")
        verify_ssl = !["false", "0", "no", false].include?(verify_ssl_raw.to_s.downcase)

        return nil if endpoint.to_s.strip.empty? || token_id.to_s.strip.empty? || token_secret.to_s.strip.empty?

        Proxmox::Client.new(
          endpoint: endpoint,
          token_id: token_id,
          token_secret: token_secret,
          verify_ssl: verify_ssl
        )
      end

      def pve_credential(column, config_key, default: nil)
        if @transient_credentials
          val = @transient_credentials[column] || @transient_credentials[column.to_sym] ||
                @transient_credentials[config_key] || @transient_credentials[config_key.to_sym]
          return val if val
        end
        return default unless connection

        # Standard ProviderConnection-level lookup: typed column, then config JSONB.
        via_connection = credential(column: column.to_sym, config_key: config_key, default: nil)
        return via_connection unless via_connection.nil?

        # Fallback to the parent Provider's config — this lets operators set
        # endpoint / verify_ssl / default_* once on the Provider (via the
        # ProviderFormModal General tab) and have every ProviderConnection
        # inherit them without re-entering on each Credentials tab visit.
        provider_cfg = connection.provider&.config
        if provider_cfg.is_a?(Hash)
          inherited = provider_cfg[config_key.to_s] || provider_cfg[config_key.to_sym]
          return inherited unless inherited.nil?
        end

        default
      end

      def missing_credentials_failure
        @last_authentication_error =
          "Missing Proxmox credentials. Required: endpoint_url, access_key (token_id like " \
          "'root@pam!powernode'), secret_key (token UUID secret). Optional: verify_ssl (default true)."
        false
      end
    end
  end
end
