# frozen_string_literal: true

require "faraday"
require "json"

module System
  module Providers
    # Microsoft Azure cloud provider adapter.
    #
    # === Why a hand-rolled REST client ===
    # Microsoft's official `azure_mgmt_compute` SDK ("Track 1" Ruby SDK)
    # transitively depends on `ms_rest_azure` which pins `faraday < 2.0`.
    # The Powernode platform pins `faraday ~> 2.0`, so the SDK is not a viable
    # dependency. Microsoft's "Track 2" Ruby SDK was discontinued in 2022, so
    # there is no maintained official SDK on the faraday-2 line. The pragmatic
    # path is a thin REST client built on the platform's existing faraday-2
    # stack — the same approach taken by `StorageProviders::AzureStorage`.
    #
    # === Coverage ===
    # Full BaseProvider interface against Azure REST API:
    #   - Connection: test_connection (OAuth2 token + subscription probe)
    #   - Lifecycle: create_instance / start / stop / restart / terminate
    #     / list / get
    #   - Catalog: list_regions / list_availability_zones / list_instance_types
    #   - IP: allocate / associate / disassociate / release (Public IP +
    #         NIC.ipConfigurations[].publicIPAddress patching)
    #   - Volumes: create / list / get / delete / attach / detach
    #     (Microsoft.Compute/disks; attach/detach via VM PUT roundtrip)
    #   - Snapshots: create / list / restore (Microsoft.Compute/snapshots
    #     + Disk Copy from sourceResourceId)
    #   - Volume types: canonical Azure managed-disk SKUs (platform-fixed)
    #
    # === Auth ===
    # OAuth2 client-credentials flow against Azure AD using the connection's
    # encrypted access_key (client_id) + secret_key (client_secret) +
    # tenant (Azure AD tenant id). Tokens are cached per-instance for their
    # validity window (typically ~55 min) to avoid round-trip per call.
    class AzureProvider < BaseProvider
      class AzureError < BaseProvider::ProviderError; end

      ARM_API_VERSION      = "2024-07-01"   # Microsoft.Compute / Microsoft.Network
      RESOURCE_API_VERSION = "2022-12-01"   # Microsoft.Resources (subscriptions, locations)
      MGMT_BASE  = "https://management.azure.com"
      LOGIN_BASE = "https://login.microsoftonline.com"

      AZURE_STATUS_MAP = {
        "PowerState/starting"        => "starting",
        "PowerState/running"         => "running",
        "PowerState/stopping"        => "stopping",
        "PowerState/stopped"         => "stopped",
        "PowerState/deallocating"    => "stopping",
        "PowerState/deallocated"     => "stopped",
        "ProvisioningState/creating" => "pending",
        "ProvisioningState/deleting" => "terminating"
      }.freeze

      def provider_type
        "azure"
      end

      # ===========================================
      # Connection / health
      # ===========================================

      # Cheap, side-effect-free authentication probe used by
      # System::CredentialValidationService (M2 BYOC). Performs a
      # client-credentials OAuth2 grant against Azure AD using only the
      # supplied tenant_id / client_id / client_secret — does NOT require
      # subscription access (which `test_connection` does). Populates
      # `last_authentication_error` on rejection so the onboarding UI
      # can surface the AAD error description (typically AADSTS-prefixed).
      def authenticate?
        @last_authentication_error = nil

        tenant         = auth_credential("tenant_id", "tenant")
        client_id_val  = auth_credential("client_id", "access_key")
        client_secret_val = auth_credential("client_secret", "secret_key")

        missing = []
        missing << "tenant_id"     if tenant.to_s.strip.empty?
        missing << "client_id"     if client_id_val.to_s.strip.empty?
        missing << "client_secret" if client_secret_val.to_s.strip.empty?
        if missing.any?
          @last_authentication_error = "missing #{missing.join(', ')}"
          return false
        end

        login_conn = Faraday.new(url: LOGIN_BASE) do |f|
          f.request :url_encoded
          f.response :json, content_type: /\bjson$/
          f.adapter Faraday.default_adapter
        end

        response = login_conn.post("/#{tenant}/oauth2/v2.0/token") do |req|
          req.body = {
            grant_type:    "client_credentials",
            client_id:     client_id_val,
            client_secret: client_secret_val,
            scope:         "#{MGMT_BASE}/.default"
          }
        end

        body = response.body
        if response.success? && body.is_a?(Hash) && !body["access_token"].to_s.empty?
          true
        else
          @last_authentication_error =
            if body.is_a?(Hash)
              body["error_description"] || body["error"] || "HTTP #{response.status}"
            else
              "HTTP #{response.status}"
            end
          false
        end
      rescue StandardError => e
        @last_authentication_error = e.message
        false
      end

      # Test that credentials work and the subscription is reachable.
      def test_connection
        token = fetch_token!
        return { success: false, error: "Failed to obtain Azure AD token" } unless token

        # Probe the subscription endpoint — minimal read; validates the token
        # AND that the principal has Reader access on the subscription.
        response = arm_get("/subscriptions/#{subscription_id}", api_version: RESOURCE_API_VERSION)
        if response.success?
          {
            success: true,
            message: "Azure connection healthy",
            subscription_id: subscription_id,
            display_name: response.body["displayName"]
          }
        else
          { success: false, error: arm_error_message(response) }
        end
      rescue StandardError => e
        { success: false, error: "Azure test_connection failed: #{e.message}" }
      end

      # ===========================================
      # Instance lifecycle
      # ===========================================

      def create_instance(params)
        log_operation("create_instance", params: params)

        rg   = params[:resource_group] || resource_group
        name = params[:name]
        body = build_vm_payload(params, name)

        response = arm_put(
          "/subscriptions/#{subscription_id}/resourceGroups/#{rg}/providers/Microsoft.Compute/virtualMachines/#{name}",
          body: body,
          api_version: ARM_API_VERSION
        )
        azure_failure!(response) unless response.success?

        vm = wait_for_provisioning(rg, name)

        build_instance_response(
          cloud_id: name,
          status: vm_power_state(vm),
          private_ip: vm_private_ip(rg, name),
          instance_type: vm.dig("properties", "hardwareProfile", "vmSize")
        )
      end

      def start_instance(instance_id)
        rg = resource_group
        response = arm_post(
          "/subscriptions/#{subscription_id}/resourceGroups/#{rg}/providers/Microsoft.Compute/virtualMachines/#{instance_id}/start",
          api_version: ARM_API_VERSION
        )
        azure_failure!(response) unless response.success?
        { success: true }
      end

      # `force: true` deallocates (releases compute, no charge);
      # otherwise just powers off (still allocated, still charged).
      def stop_instance(instance_id, force: false)
        rg = resource_group
        endpoint = force ? "deallocate" : "powerOff"
        response = arm_post(
          "/subscriptions/#{subscription_id}/resourceGroups/#{rg}/providers/Microsoft.Compute/virtualMachines/#{instance_id}/#{endpoint}",
          api_version: ARM_API_VERSION
        )
        azure_failure!(response) unless response.success?
        { success: true }
      end

      # Renamed from restart_instance to match BaseProvider#reboot_instance.
      # The underlying Azure REST endpoint is still /restart — that's the
      # ARM verb name, distinct from our platform vocabulary.
      def reboot_instance(instance_id)
        rg = resource_group
        response = arm_post(
          "/subscriptions/#{subscription_id}/resourceGroups/#{rg}/providers/Microsoft.Compute/virtualMachines/#{instance_id}/restart",
          api_version: ARM_API_VERSION
        )
        azure_failure!(response) unless response.success?
        { success: true }
      end

      def terminate_instance(instance_id)
        rg = resource_group
        response = arm_delete(
          "/subscriptions/#{subscription_id}/resourceGroups/#{rg}/providers/Microsoft.Compute/virtualMachines/#{instance_id}",
          api_version: ARM_API_VERSION
        )
        azure_failure!(response) unless response.success?
        { success: true }
      end

      # @param filters [Hash] cloud-side filters plus pagination knobs
      #   :resource_group [String] scope listing to a specific RG (else subscription-wide)
      #   :max_pages      [Integer, nil] stop after N pages (default 100, nil = unbounded)
      #
      # Returns the standard adapter contract: { success:, instances:,
      #   page_count:, truncated: } — Azure was previously the lone adapter
      #   that returned a bare Array, which broke CloudSyncService's
      #   `result[:success]` check.
      def list_instances(filters = {})
        rg = filters[:resource_group] || resource_group
        base_path = if rg
                      "/subscriptions/#{subscription_id}/resourceGroups/#{rg}/providers/Microsoft.Compute/virtualMachines"
        else
                      "/subscriptions/#{subscription_id}/providers/Microsoft.Compute/virtualMachines"
        end

        max_pages = filters.key?(:max_pages) ? filters[:max_pages] : 100

        instances = []
        next_link = nil
        page_count = 0
        truncated = false

        loop do
          response = next_link ? arm_get_url(next_link) : arm_get(base_path, api_version: ARM_API_VERSION)
          azure_failure!(response) unless response.success?

          Array(response.body["value"]).each do |vm|
            instances << {
              cloud_id: vm["name"],
              name: vm["name"],
              status: vm_power_state(vm),
              instance_type: vm.dig("properties", "hardwareProfile", "vmSize"),
              location: vm["location"],
              resource_group: vm["id"]&.split("/")&.[](4)
            }
          end

          next_link = response.body["nextLink"]
          page_count += 1
          break if next_link.nil? || next_link.empty?
          if max_pages && page_count >= max_pages
            truncated = true
            break
          end
        end

        { success: true, instances: instances, page_count: page_count, truncated: truncated }
      end

      def get_instance(instance_id)
        rg = resource_group
        response = arm_get(
          "/subscriptions/#{subscription_id}/resourceGroups/#{rg}/providers/Microsoft.Compute/virtualMachines/#{instance_id}",
          api_version: ARM_API_VERSION,
          query: { "$expand" => "instanceView" }
        )
        return nil unless response.success?

        vm = response.body
        {
          cloud_id: vm["name"],
          name: vm["name"],
          status: vm_power_state(vm),
          instance_type: vm.dig("properties", "hardwareProfile", "vmSize"),
          location: vm["location"],
          private_ip: vm_private_ip(rg, instance_id),
          public_ip: vm_public_ip(rg, instance_id)
        }
      end

      # ===========================================
      # Catalog (regions / zones / instance types)
      # ===========================================

      def list_regions
        response = arm_get(
          "/subscriptions/#{subscription_id}/locations",
          api_version: RESOURCE_API_VERSION
        )
        return [] unless response.success?

        Array(response.body["value"]).map do |loc|
          {
            cloud_id: loc["name"],
            name: loc["displayName"],
            geography: loc["metadata"]&.dig("geographyGroup")
          }
        end
      end

      def list_availability_zones(region)
        response = arm_get(
          "/subscriptions/#{subscription_id}/providers/Microsoft.Compute/skus",
          api_version: ARM_API_VERSION,
          query: { "$filter" => "location eq '#{region}'" }
        )
        return [] unless response.success?

        zones = Array(response.body["value"])
                  .flat_map { |sku| Array(sku["locationInfo"]).flat_map { |li| Array(li["zones"]) } }
                  .uniq
                  .sort
        zones.map { |z| { cloud_id: z, name: "Zone #{z}" } }
      end

      def list_instance_types(region)
        response = arm_get(
          "/subscriptions/#{subscription_id}/providers/Microsoft.Compute/skus",
          api_version: ARM_API_VERSION,
          query: { "$filter" => "location eq '#{region}'" }
        )
        return [] unless response.success?

        Array(response.body["value"])
          .select { |sku| sku["resourceType"] == "virtualMachines" }
          .map do |sku|
            cap = (sku["capabilities"] || []).each_with_object({}) { |c, h| h[c["name"]] = c["value"] }
            {
              cloud_id: sku["name"],
              name: sku["name"],
              vcpus: cap["vCPUs"]&.to_i,
              memory_gb: cap["MemoryGB"]&.to_f,
              family: sku["family"]
            }
          end
      end

      # ===========================================
      # Public IP management
      # ===========================================
      #
      # Azure's IP allocation flow is two resources:
      #   1. allocate_ip   → create a Microsoft.Network/publicIPAddresses
      #   2. associate_ip  → patch the VM's NIC ipConfigurations to point at it
      # And the reverse for release. The "association_id" we expose to callers
      # is the NIC's resource id since that's what holds the IP-to-NIC binding.

      def allocate_ip
        rg = resource_group
        # Generate a deterministic IP resource name. Caller passes the IP
        # name through `instance_id` in associate_ip; here we mint a new one.
        name = "powernode-eip-#{SecureRandom.hex(6)}"

        body = {
          location: default_location,
          sku:      { name: "Standard" },
          properties: {
            publicIPAddressVersion:   "IPv4",
            publicIPAllocationMethod: "Static"
          }
        }

        response = arm_put(
          "/subscriptions/#{subscription_id}/resourceGroups/#{rg}/providers/Microsoft.Network/publicIPAddresses/#{name}",
          body: body,
          api_version: ARM_API_VERSION
        )
        azure_failure!(response) unless response.success?

        ip_resource = wait_for_resource(
          "/subscriptions/#{subscription_id}/resourceGroups/#{rg}/providers/Microsoft.Network/publicIPAddresses/#{name}",
          desired_state: "Succeeded"
        )

        {
          success: true,
          allocation_id: name,
          public_ip:     ip_resource.dig("properties", "ipAddress")
        }
      end

      def associate_ip(instance_id, allocation_id:)
        rg = resource_group

        nic_id = primary_nic_id(rg, instance_id)
        raise ResourceNotFoundError, "Instance #{instance_id} has no primary NIC" unless nic_id

        nic_response = arm_get(nic_id, api_version: ARM_API_VERSION)
        azure_failure!(nic_response) unless nic_response.success?

        nic = nic_response.body
        ip_config = nic.dig("properties", "ipConfigurations", 0)
        raise ProviderError, "Primary NIC has no ipConfiguration" unless ip_config

        public_ip_id = "/subscriptions/#{subscription_id}/resourceGroups/#{rg}/providers/Microsoft.Network/publicIPAddresses/#{allocation_id}"
        ip_config["properties"]["publicIPAddress"] = { id: public_ip_id }

        update = arm_put(nic_id, body: nic.slice("location", "properties"), api_version: ARM_API_VERSION)
        azure_failure!(update) unless update.success?

        wait_for_resource(nic_id, desired_state: "Succeeded")

        # Resolve the IP for the response
        ip_resource = arm_get(public_ip_id, api_version: ARM_API_VERSION)
        public_ip = ip_resource.success? ? ip_resource.body.dig("properties", "ipAddress") : nil

        { success: true, public_ip: public_ip, association_id: nic_id }
      end

      # `association_id` is the NIC resource id (set by associate_ip above).
      # We GET the NIC, clear publicIPAddress on its primary ipConfiguration,
      # PUT it back. The Public IP resource itself is untouched (still allocated).
      def disassociate_ip(association_id)
        nic_response = arm_get(association_id, api_version: ARM_API_VERSION)
        azure_failure!(nic_response) unless nic_response.success?

        nic = nic_response.body
        ip_config = nic.dig("properties", "ipConfigurations", 0)
        raise ProviderError, "NIC has no ipConfiguration to disassociate" unless ip_config

        ip_config["properties"].delete("publicIPAddress")

        update = arm_put(association_id, body: nic.slice("location", "properties"), api_version: ARM_API_VERSION)
        azure_failure!(update) unless update.success?

        wait_for_resource(association_id, desired_state: "Succeeded")
        { success: true }
      end

      def release_ip(allocation_id)
        rg = resource_group
        response = arm_delete(
          "/subscriptions/#{subscription_id}/resourceGroups/#{rg}/providers/Microsoft.Network/publicIPAddresses/#{allocation_id}",
          api_version: ARM_API_VERSION
        )
        azure_failure!(response) unless response.success?
        { success: true }
      end

      # ===========================================
      # Volume (managed disk) operations
      # ===========================================

      def create_volume(params)
        rg   = params[:resource_group] || resource_group
        name = params[:name] || "powernode-vol-#{SecureRandom.hex(6)}"

        body = {
          location: params[:region] || default_location,
          sku:      { name: params[:volume_type] || "Standard_LRS" },
          properties: {
            diskSizeGB:   params[:size_gb] || 8,
            creationData: { createOption: "Empty" }
          }
        }

        response = arm_put(
          "/subscriptions/#{subscription_id}/resourceGroups/#{rg}/providers/Microsoft.Compute/disks/#{name}",
          body: body,
          api_version: ARM_API_VERSION
        )
        azure_failure!(response) unless response.success?

        disk = wait_for_resource(
          "/subscriptions/#{subscription_id}/resourceGroups/#{rg}/providers/Microsoft.Compute/disks/#{name}",
          desired_state: "Succeeded"
        )

        {
          success:    true,
          volume_id:  name,
          size_gb:    disk.dig("properties", "diskSizeGB"),
          state:      disk.dig("properties", "diskState"),
          location:   disk["location"]
        }
      end

      def list_volumes(filters = {})
        rg = filters[:resource_group] || resource_group
        path = if rg
                 "/subscriptions/#{subscription_id}/resourceGroups/#{rg}/providers/Microsoft.Compute/disks"
        else
                 "/subscriptions/#{subscription_id}/providers/Microsoft.Compute/disks"
        end

        response = arm_get(path, api_version: ARM_API_VERSION)
        return [] unless response.success?

        Array(response.body["value"]).map do |d|
          {
            volume_id: d["name"],
            size_gb:   d.dig("properties", "diskSizeGB"),
            state:     d.dig("properties", "diskState"),
            location:  d["location"],
            sku:       d.dig("sku", "name"),
            attached_to: d.dig("properties", "managedBy")
          }
        end
      end

      def get_volume(volume_id)
        rg = resource_group
        response = arm_get(
          "/subscriptions/#{subscription_id}/resourceGroups/#{rg}/providers/Microsoft.Compute/disks/#{volume_id}",
          api_version: ARM_API_VERSION
        )
        return nil unless response.success?

        d = response.body
        {
          volume_id:   d["name"],
          size_gb:     d.dig("properties", "diskSizeGB"),
          state:       d.dig("properties", "diskState"),
          location:    d["location"],
          sku:         d.dig("sku", "name"),
          attached_to: d.dig("properties", "managedBy")
        }
      end

      def delete_volume(volume_id)
        rg = resource_group
        response = arm_delete(
          "/subscriptions/#{subscription_id}/resourceGroups/#{rg}/providers/Microsoft.Compute/disks/#{volume_id}",
          api_version: ARM_API_VERSION
        )
        azure_failure!(response) unless response.success?
        { success: true }
      end

      # Azure attach/detach: GET the VM, modify storageProfile.dataDisks,
      # PUT it back. There's no dedicated attach/detach endpoint.
      def attach_volume(volume_id, instance_id, device: nil)
        rg = resource_group
        vm_path = "/subscriptions/#{subscription_id}/resourceGroups/#{rg}/providers/Microsoft.Compute/virtualMachines/#{instance_id}"

        vm_response = arm_get(vm_path, api_version: ARM_API_VERSION)
        azure_failure!(vm_response) unless vm_response.success?

        vm = vm_response.body
        data_disks = vm.dig("properties", "storageProfile", "dataDisks") || []
        lun = next_data_disk_lun(data_disks)

        data_disks << {
          lun:          lun,
          name:         volume_id,
          createOption: "Attach",
          managedDisk: {
            id: "/subscriptions/#{subscription_id}/resourceGroups/#{rg}/providers/Microsoft.Compute/disks/#{volume_id}"
          }
        }
        vm["properties"]["storageProfile"]["dataDisks"] = data_disks

        update = arm_put(vm_path, body: vm.slice("location", "properties"), api_version: ARM_API_VERSION)
        azure_failure!(update) unless update.success?

        wait_for_resource(vm_path, desired_state: "Succeeded")
        { success: true, device: device || "/dev/disk/azure/scsi1/lun#{lun}" }
      end

      # BaseProvider contract: detach_volume(volume_id, force: false). Azure
      # natively requires the attached VM to mutate storageProfile.dataDisks,
      # so we look up `managedBy` from the disk resource (which is the VM's
      # ARM id) instead of asking the caller. `force` is accepted for
      # contract parity but Azure has no soft-vs-hard distinction here.
      def detach_volume(volume_id, force: false) # rubocop:disable Lint/UnusedMethodArgument
        vol = get_volume(volume_id)
        raise ResourceNotFoundError, "Volume #{volume_id} not found" unless vol

        vm_resource_id = vol[:attached_to]
        return { success: true, message: "Volume #{volume_id} already detached" } unless vm_resource_id.present?

        # Parse VM resource group + name from the ARM resource id rather than
        # assume same-RG, since disks and VMs can live in different RGs.
        rg = vm_resource_id[%r{/resourceGroups/([^/]+)}, 1] || resource_group
        instance_id = vm_resource_id.split("/").last

        vm_path = "/subscriptions/#{subscription_id}/resourceGroups/#{rg}/providers/Microsoft.Compute/virtualMachines/#{instance_id}"
        vm_response = arm_get(vm_path, api_version: ARM_API_VERSION)
        azure_failure!(vm_response) unless vm_response.success?

        vm = vm_response.body
        data_disks = vm.dig("properties", "storageProfile", "dataDisks") || []
        before = data_disks.size
        data_disks.reject! { |d| d["name"] == volume_id }

        # Race: managedBy said attached but the VM's dataDisks no longer
        # contain it. Treat as success (idempotent).
        return { success: true, message: "Volume #{volume_id} already removed from #{instance_id}" } if data_disks.size == before

        vm["properties"]["storageProfile"]["dataDisks"] = data_disks
        update = arm_put(vm_path, body: vm.slice("location", "properties"), api_version: ARM_API_VERSION)
        azure_failure!(update) unless update.success?

        wait_for_resource(vm_path, desired_state: "Succeeded")
        { success: true }
      end

      # ===========================================
      # Snapshots
      # ===========================================

      def create_snapshot(volume_id, params = {})
        rg   = resource_group
        name = params[:name] || "snap-#{volume_id}-#{Time.now.to_i}"

        body = {
          location: params[:region] || default_location,
          properties: {
            creationData: {
              createOption:    "Copy",
              sourceResourceId: "/subscriptions/#{subscription_id}/resourceGroups/#{rg}/providers/Microsoft.Compute/disks/#{volume_id}"
            }
          }
        }

        response = arm_put(
          "/subscriptions/#{subscription_id}/resourceGroups/#{rg}/providers/Microsoft.Compute/snapshots/#{name}",
          body: body,
          api_version: ARM_API_VERSION
        )
        azure_failure!(response) unless response.success?

        snap = wait_for_resource(
          "/subscriptions/#{subscription_id}/resourceGroups/#{rg}/providers/Microsoft.Compute/snapshots/#{name}",
          desired_state: "Succeeded"
        )

        {
          success:    true,
          snapshot_id: name,
          volume_id:   volume_id,
          state:       snap.dig("properties", "provisioningState"),
          size_gb:     snap.dig("properties", "diskSizeGB")
        }
      end

      def list_snapshots(filters = {})
        rg = filters[:resource_group] || resource_group
        response = arm_get(
          "/subscriptions/#{subscription_id}/resourceGroups/#{rg}/providers/Microsoft.Compute/snapshots",
          api_version: ARM_API_VERSION
        )
        return [] unless response.success?

        Array(response.body["value"]).map do |s|
          {
            snapshot_id: s["name"],
            state:       s.dig("properties", "provisioningState"),
            size_gb:     s.dig("properties", "diskSizeGB"),
            source:      s.dig("properties", "creationData", "sourceResourceId"),
            created_at:  s.dig("properties", "timeCreated")
          }
        end
      end

      # Restore = create a new disk from the snapshot's source data.
      # Returns the newly-created volume.
      def restore_snapshot(snapshot_id, params = {})
        rg   = resource_group
        name = params[:volume_name] || "restored-#{snapshot_id}-#{Time.now.to_i}"

        body = {
          location: params[:region] || default_location,
          sku:      { name: params[:volume_type] || "Standard_LRS" },
          properties: {
            creationData: {
              createOption:     "Copy",
              sourceResourceId: "/subscriptions/#{subscription_id}/resourceGroups/#{rg}/providers/Microsoft.Compute/snapshots/#{snapshot_id}"
            }
          }
        }

        response = arm_put(
          "/subscriptions/#{subscription_id}/resourceGroups/#{rg}/providers/Microsoft.Compute/disks/#{name}",
          body: body,
          api_version: ARM_API_VERSION
        )
        azure_failure!(response) unless response.success?

        disk = wait_for_resource(
          "/subscriptions/#{subscription_id}/resourceGroups/#{rg}/providers/Microsoft.Compute/disks/#{name}",
          desired_state: "Succeeded"
        )

        { success: true, volume_id: name, size_gb: disk.dig("properties", "diskSizeGB") }
      end

      # Azure managed-disk SKUs are platform-fixed (not region-discoverable).
      # Returning the canonical set so the catalog ingestion has stable rows.
      # ===========================================
      # Images (Microsoft.Compute/images)
      # ===========================================
      #
      # Image capture/restore against Azure managed images is a future
      # iteration — the platform's primary image flow runs through the
      # System::ImageCreationService which produces FileManagement::Object
      # blobs, not cloud-native images. These stubs satisfy the BaseProvider
      # contract (interface compliance) and raise the typed ProviderError
      # so callers handle them consistently with other unsupported paths.

      def create_image(_instance_id, name:, description: nil) # rubocop:disable Lint/UnusedMethodArgument
        log_operation("create_image", name: name)
        raise ProviderError, "AzureProvider#create_image is not yet supported"
      end

      def get_image(_image_id)
        raise ProviderError, "AzureProvider#get_image is not yet supported"
      end

      def delete_image(_image_id)
        raise ProviderError, "AzureProvider#delete_image is not yet supported"
      end

      # Map a cloud-side power state string (e.g. "PowerState/running") to a
      # platform status. Status keys come from AZURE_STATUS_MAP. Anything not
      # in the map falls back to "unknown" — the platform-wide convention
      # asserted by `shared_examples "a cloud provider with status
      # normalization"`.
      def normalize_status(provider_status)
        AZURE_STATUS_MAP[provider_status.to_s] || "unknown"
      end

      def list_volume_types(_region)
        [
          { cloud_id: "Standard_LRS",     name: "Standard HDD",    iops: nil,   throughput_mbps: nil },
          { cloud_id: "StandardSSD_LRS",  name: "Standard SSD",    iops: nil,   throughput_mbps: nil },
          { cloud_id: "Premium_LRS",      name: "Premium SSD",     iops: nil,   throughput_mbps: nil },
          { cloud_id: "PremiumV2_LRS",    name: "Premium SSD v2",  iops: nil,   throughput_mbps: nil },
          { cloud_id: "UltraSSD_LRS",     name: "Ultra Disk",      iops: nil,   throughput_mbps: nil },
          { cloud_id: "StandardSSD_ZRS",  name: "Standard SSD (zone-redundant)", iops: nil, throughput_mbps: nil },
          { cloud_id: "Premium_ZRS",      name: "Premium SSD (zone-redundant)",  iops: nil, throughput_mbps: nil }
        ]
      end

      private

      # ----- credentials + connection settings -----

      # Resolve an auth-probe credential — transient creds (M2 BYOC test
      # flow) win; otherwise fall back to the connection columns via the
      # BaseProvider credential helper. Differs from `tenant_id` /
      # `client_id` etc. (which raise when missing) by returning nil so
      # the auth probe can compose a "missing X, Y, Z" error message.
      def auth_credential(*keys)
        if @transient_credentials
          keys.each do |key|
            value = @transient_credentials[key.to_s] || @transient_credentials[key.to_sym]
            return value if value.respond_to?(:present?) ? value.present? : !value.to_s.empty?
          end
          return nil
        end

        return nil unless connection
        keys.each do |key|
          value = credential(column: key.to_sym, config_key: key.to_s)
          return value if value.respond_to?(:present?) ? value.present? : !value.to_s.empty?
        end
        nil
      end

      def tenant_id
        credential(column: :tenant, required: true)
      end

      def client_id
        credential(column: :access_key, required: true)
      end

      def client_secret
        credential(column: :secret_key, required: true)
      end

      def subscription_id
        credential(config_key: "subscription_id", required: true)
      end

      def resource_group
        credential(config_key: "resource_group", default: "powernode-default")
      end

      # ----- HTTP helpers -----

      def fetch_token!
        return @token if @token && @token_expires_at && @token_expires_at > Time.now + 60

        login_conn = Faraday.new(url: LOGIN_BASE) do |f|
          f.request :url_encoded
          f.response :json, content_type: /\bjson$/
          f.adapter Faraday.default_adapter
        end

        response = login_conn.post("/#{tenant_id}/oauth2/v2.0/token") do |req|
          req.body = {
            grant_type:    "client_credentials",
            client_id:     client_id,
            client_secret: client_secret,
            scope:         "#{MGMT_BASE}/.default"
          }
        end

        unless response.success?
          raise AzureError, "Azure AD token exchange failed: #{response.status}"
        end

        @token = response.body["access_token"]
        @token_expires_at = Time.now + response.body["expires_in"].to_i
        @token
      end

      def arm_get(path, api_version:, query: {})
        arm_request(:get, path, api_version: api_version, query: query)
      end

      def arm_post(path, body: nil, api_version:, query: {})
        arm_request(:post, path, body: body, api_version: api_version, query: query)
      end

      def arm_put(path, body:, api_version:, query: {})
        arm_request(:put, path, body: body, api_version: api_version, query: query)
      end

      def arm_delete(path, api_version:, query: {})
        arm_request(:delete, path, api_version: api_version, query: query)
      end

      def arm_request(method, path, api_version:, body: nil, query: {})
        token = fetch_token!
        full_query = { "api-version" => api_version }.merge(query)

        arm_connection.public_send(method, path) do |req|
          req.params.update(full_query)
          req.headers["Authorization"] = "Bearer #{token}"
          req.headers["Content-Type"]  = "application/json" if body
          req.body = body.to_json if body
        end
      end

      # Follow an ARM `nextLink` (absolute URL) without re-applying api-version
      # or query params — Azure embeds them in the link itself. Faraday treats
      # an absolute URL as a host override on the existing connection.
      def arm_get_url(absolute_url)
        token = fetch_token!
        arm_connection.get(absolute_url) do |req|
          req.headers["Authorization"] = "Bearer #{token}"
        end
      end

      def arm_connection
        @arm_connection ||= Faraday.new(url: MGMT_BASE) do |f|
          f.response :json, content_type: /\bjson$/
          f.options.timeout      = 60
          f.options.open_timeout = 10
          f.adapter Faraday.default_adapter
        end
      end

      # ----- VM payload + status helpers -----

      def build_vm_payload(params, _name)
        {
          location: params[:region] || params[:location],
          properties: {
            hardwareProfile: { vmSize: params[:instance_type] || "Standard_B1s" },
            storageProfile: {
              imageReference: params[:image_reference] || default_ubuntu_image,
              osDisk: {
                createOption: "FromImage",
                managedDisk: { storageAccountType: "Standard_LRS" }
              }
            },
            osProfile: {
              computerName:   params[:name],
              adminUsername:  params[:admin_user] || "powernode",
              linuxConfiguration: {
                disablePasswordAuthentication: true,
                ssh: {
                  publicKeys: [ {
                    path: "/home/#{params[:admin_user] || 'powernode'}/.ssh/authorized_keys",
                    keyData: params[:ssh_public_key]
                  } ]
                }
              }
            },
            networkProfile: {
              networkInterfaces: [ { id: params[:network_interface_id] } ]
            }
          }
        }
      end

      def default_ubuntu_image
        {
          publisher: "Canonical",
          offer:     "0001-com-ubuntu-server-jammy",
          sku:       "22_04-lts-gen2",
          version:   "latest"
        }
      end

      def wait_for_provisioning(rg, name, max_wait: 300, interval: 5)
        deadline = Time.now + max_wait
        loop do
          response = arm_get(
            "/subscriptions/#{subscription_id}/resourceGroups/#{rg}/providers/Microsoft.Compute/virtualMachines/#{name}",
            api_version: ARM_API_VERSION
          )
          raise AzureError, "VM provisioning poll failed: #{response.status}" unless response.success?

          state = response.body.dig("properties", "provisioningState")
          return response.body if %w[Succeeded Failed Canceled].include?(state)
          raise AzureError, "VM provisioning timeout after #{max_wait}s" if Time.now > deadline

          sleep interval
        end
      end

      def vm_power_state(vm)
        view = vm.dig("properties", "instanceView")
        return AZURE_STATUS_MAP["ProvisioningState/creating"] || "pending" unless view

        statuses = view["statuses"] || []
        power = statuses.map { |s| s["code"] }.find { |c| c.start_with?("PowerState/") }
        AZURE_STATUS_MAP[power] || "running"
      end

      def vm_private_ip(rg, name)
        response = arm_get(
          "/subscriptions/#{subscription_id}/resourceGroups/#{rg}/providers/Microsoft.Compute/virtualMachines/#{name}/networkInterfaces",
          api_version: ARM_API_VERSION
        )
        return nil unless response.success?

        Array(response.body["value"]).first&.dig("properties", "ipConfigurations", 0, "properties", "privateIPAddress")
      end

      def vm_public_ip(rg, name)
        # Walk NIC → ipConfigurations[0].properties.publicIPAddress.id →
        # public IP resource → properties.ipAddress.
        nic_id = primary_nic_id(rg, name)
        return nil unless nic_id

        nic_response = arm_get(nic_id, api_version: ARM_API_VERSION)
        return nil unless nic_response.success?

        public_ip_ref = nic_response.body.dig("properties", "ipConfigurations", 0, "properties", "publicIPAddress", "id")
        return nil unless public_ip_ref

        ip_response = arm_get(public_ip_ref, api_version: ARM_API_VERSION)
        return nil unless ip_response.success?

        ip_response.body.dig("properties", "ipAddress")
      end

      # Walk the VM → networkInterfaces collection and return the primary
      # NIC's resource id. Phase 1 assumes one NIC per VM (the create_instance
      # payload only attaches one). Multi-NIC support arrives with the
      # advanced-networking feature flag.
      def primary_nic_id(rg, instance_id)
        vm_response = arm_get(
          "/subscriptions/#{subscription_id}/resourceGroups/#{rg}/providers/Microsoft.Compute/virtualMachines/#{instance_id}",
          api_version: ARM_API_VERSION
        )
        return nil unless vm_response.success?

        nics = vm_response.body.dig("properties", "networkProfile", "networkInterfaces") || []
        primary = nics.find { |n| n.dig("properties", "primary") } || nics.first
        primary&.dig("id")
      end

      def next_data_disk_lun(existing_disks)
        used = existing_disks.map { |d| d["lun"] }.compact
        (0..63).find { |i| !used.include?(i) } || 0
      end

      def default_location
        (connection.config && connection.config["default_location"]) || "eastus"
      end

      # Poll an ARM resource until its provisioningState reaches `desired_state`
      # (or one of the terminal states). Returns the resource body.
      def wait_for_resource(resource_path, desired_state:, max_wait: 300, interval: 5)
        deadline = Time.now + max_wait
        loop do
          response = arm_get(resource_path, api_version: ARM_API_VERSION)
          raise AzureError, "Resource poll failed: #{response.status}" unless response.success?

          state = response.body.dig("properties", "provisioningState")
          return response.body if [ desired_state, "Failed", "Canceled" ].include?(state)
          raise AzureError, "Resource provisioning timeout after #{max_wait}s for #{resource_path}" if Time.now > deadline

          sleep interval
        end
      end

      def arm_error_message(response)
        body = response.body
        return "HTTP #{response.status}" unless body.is_a?(Hash)
        body.dig("error", "message") || body["message"] || "HTTP #{response.status}"
      end

      # Translate an unsuccessful ARM response into the appropriate
      # BaseProvider exception family. Mirrors the AWS/GCP adapter contract
      # so callers can `rescue Providers::BaseProvider::ProviderError` once
      # and trust they've handled all failure paths.
      def azure_failure!(response)
        message = arm_error_message(response)
        case response.status
        when 401, 403
          raise AuthenticationError, message
        when 404
          raise ResourceNotFoundError, message
        when 429
          raise RateLimitError, message
        when 402
          raise QuotaExceededError, message
        else
          raise ProviderError, "HTTP #{response.status}: #{message}"
        end
      end

      def log_operation(action, params: {})
        safe = params.is_a?(Hash) ? params.except(:secret_key, :access_key, :ssh_public_key) : {}
        Rails.logger.info("[AzureProvider] #{action} #{safe.inspect}")
      end

      def build_instance_response(cloud_id:, status:, private_ip: nil, instance_type: nil)
        {
          success: true,
          cloud_instance_id: cloud_id,
          status: status,
          private_ip: private_ip,
          instance_type: instance_type
        }
      end
    end
  end
end
