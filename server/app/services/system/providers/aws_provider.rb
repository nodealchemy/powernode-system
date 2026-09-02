# frozen_string_literal: true

module System
  module Providers
    # AWS EC2 cloud provider adapter
    # Uses aws-sdk-ec2 for cloud operations
    class AwsProvider < BaseProvider
      # aws-sdk-ec2 is NOT in the core bundle (APO-7). Declaring it here is
      # what makes Registry hide "aws" and refuse with a named gem instead of
      # letting the first call raise NameError: uninitialized constant Aws.
      def self.required_sdk_gem
        "aws-sdk-ec2"
      end

      def self.sdk_constant
        "Aws::EC2::Client"
      end

      # AWS-specific status mappings
      AWS_STATUS_MAP = {
        "pending" => "pending",
        "running" => "running",
        "shutting-down" => "stopping",
        "terminated" => "terminated",
        "stopping" => "stopping",
        "stopped" => "stopped"
      }.freeze

      def provider_type
        "aws"
      end

      # ===========================================
      # Instance Lifecycle Operations
      # ===========================================

      def create_instance(params)
        log_operation("create_instance", params: params.except(:user_data))

        # M4 Enterprise polish — when ProvisioningService passes through
        # an IP allowlist via :security_group_rules, materialize a
        # dedicated EC2 Security Group with those rules and prepend its
        # id to :security_group_ids. We append rather than replace so
        # operators can still attach baseline SGs (VPC defaults, etc.).
        params = ensure_allowlist_security_group(params)

        run_params = build_run_instance_params(params)

        begin
          # Tagging rides atomically on run_instances (via tag_specifications,
          # assembled in build_run_instance_params) so the instance is born
          # tagged. A separate post-create create_tags call could fail (missing
          # ec2:CreateTags IAM, throttling) AFTER the billable instance had
          # already launched, orphaning a running, untagged instance whose id
          # was discarded — a permanent billable leak.
          response = ec2_client.run_instances(run_params)
          instance = response.instances.first

          build_instance_response(
            cloud_id: instance.instance_id,
            status: normalize_status(instance.state.name),
            private_ip: instance.private_ip_address,
            instance_type: instance.instance_type
          )
        rescue Aws::EC2::Errors::ServiceError => e
          handle_aws_error(e)
        end
      end

      def start_instance(instance_id)
        log_operation("start_instance", instance_id: instance_id)

        begin
          ec2_client.start_instances(instance_ids: [ instance_id ])

          # Get updated instance state
          instance_data = describe_instance(instance_id)
          return instance_data unless instance_data[:success]

          build_instance_response(
            cloud_id: instance_id,
            status: "starting",
            private_ip: instance_data[:private_ip_address],
            public_ip: instance_data[:public_ip_address]
          )
        rescue Aws::EC2::Errors::ServiceError => e
          handle_aws_error(e)
        end
      end

      def stop_instance(instance_id, force: false)
        log_operation("stop_instance", instance_id: instance_id, force: force)

        begin
          ec2_client.stop_instances(
            instance_ids: [ instance_id ],
            force: force
          )

          instance_data = describe_instance(instance_id)
          return instance_data unless instance_data[:success]

          build_instance_response(
            cloud_id: instance_id,
            status: "stopping",
            private_ip: instance_data[:private_ip_address]
          )
        rescue Aws::EC2::Errors::ServiceError => e
          handle_aws_error(e)
        end
      end

      def reboot_instance(instance_id)
        log_operation("reboot_instance", instance_id: instance_id)

        begin
          ec2_client.reboot_instances(instance_ids: [ instance_id ])

          instance_data = describe_instance(instance_id)
          return instance_data unless instance_data[:success]

          build_instance_response(
            cloud_id: instance_id,
            status: "rebooting",
            private_ip: instance_data[:private_ip_address],
            public_ip: instance_data[:public_ip_address]
          )
        rescue Aws::EC2::Errors::ServiceError => e
          handle_aws_error(e)
        end
      end

      # expected_name is accepted and ignored: only Proxmox can recycle a guest id
      # across nodes, so only it needs the second identity signal. Declared here so
      # the shared caller (ProvisioningService) can pass it uniformly.
      def terminate_instance(instance_id, expected_name: nil)
        log_operation("terminate_instance", instance_id: instance_id)

        begin
          ec2_client.terminate_instances(instance_ids: [ instance_id ])

          build_instance_response(
            cloud_id: instance_id,
            status: "terminating"
          )
        rescue Aws::EC2::Errors::ServiceError => e
          handle_aws_error(e)
        end
      end

      def get_instance(instance_id)
        log_operation("get_instance", instance_id: instance_id)
        describe_instance(instance_id)
      end

      # @param filters [Hash] cloud-side filters plus pagination knobs
      #   :per_page  [Integer] max instances per API call (AWS caps at 1000)
      #   :max_pages [Integer, nil] stop after N pages (default 100, nil = unbounded)
      def list_instances(filters = {})
        log_operation("list_instances", filters: filters)

        ec2_filters = build_ec2_filters(filters)
        per_page    = filters[:per_page]
        max_pages   = filters.key?(:max_pages) ? filters[:max_pages] : 100

        instances = []
        next_token = nil
        page_count = 0
        truncated  = false

        begin
          loop do
            params = { filters: ec2_filters }
            params[:next_token]  = next_token if next_token
            params[:max_results] = per_page if per_page

            response = ec2_client.describe_instances(**params)
            response.reservations.each do |reservation|
              reservation.instances.each do |instance|
                instances << build_instance_response(
                  cloud_id: instance.instance_id,
                  status: normalize_status(instance.state.name),
                  private_ip: instance.private_ip_address,
                  public_ip: instance.public_ip_address,
                  instance_type: instance.instance_type
                )
              end
            end

            next_token = response.next_token
            page_count += 1
            break if next_token.nil? || next_token.empty?
            if max_pages && page_count >= max_pages
              truncated = true
              break
            end
          end

          { success: true, instances: instances, page_count: page_count, truncated: truncated }
        rescue Aws::EC2::Errors::ServiceError => e
          handle_aws_error(e)
        end
      end

      # ===========================================
      # IP Address Operations
      # ===========================================

      def allocate_ip
        log_operation("allocate_ip")

        begin
          response = ec2_client.allocate_address(domain: "vpc")

          {
            success: true,
            allocation_id: response.allocation_id,
            public_ip: response.public_ip
          }
        rescue Aws::EC2::Errors::ServiceError => e
          handle_aws_error(e)
        end
      end

      def associate_ip(instance_id, allocation_id: nil)
        log_operation("associate_ip", instance_id: instance_id, allocation_id: allocation_id)

        begin
          # Allocate new IP if not provided
          unless allocation_id
            alloc_result = allocate_ip
            return alloc_result unless alloc_result[:success]
            allocation_id = alloc_result[:allocation_id]
          end

          response = ec2_client.associate_address(
            instance_id: instance_id,
            allocation_id: allocation_id
          )

          # Get the public IP
          address = ec2_client.describe_addresses(allocation_ids: [ allocation_id ]).addresses.first

          {
            success: true,
            public_ip: address&.public_ip,
            allocation_id: allocation_id,
            association_id: response.association_id
          }
        rescue Aws::EC2::Errors::ServiceError => e
          handle_aws_error(e)
        end
      end

      def disassociate_ip(association_id)
        log_operation("disassociate_ip", association_id: association_id)

        begin
          ec2_client.disassociate_address(association_id: association_id)
          { success: true }
        rescue Aws::EC2::Errors::ServiceError => e
          handle_aws_error(e)
        end
      end

      def release_ip(allocation_id)
        log_operation("release_ip", allocation_id: allocation_id)

        begin
          ec2_client.release_address(allocation_id: allocation_id)
          { success: true }
        rescue Aws::EC2::Errors::ServiceError => e
          handle_aws_error(e)
        end
      end

      # ===========================================
      # Volume Operations
      # ===========================================

      def create_volume(params)
        log_operation("create_volume", params: params)

        begin
          volume_params = {
            size: params[:size_gb],
            volume_type: params[:volume_type] || "gp3",
            availability_zone: params[:availability_zone] || default_availability_zone
          }

          volume_params[:iops] = params[:iops] if params[:iops]
          volume_params[:throughput] = params[:throughput] if params[:throughput]
          volume_params[:encrypted] = params[:encrypted] if params.key?(:encrypted)
          volume_params[:kms_key_id] = params[:kms_key_id] if params[:kms_key_id]

          response = ec2_client.create_volume(volume_params)

          {
            success: true,
            volume_id: response.volume_id,
            status: response.state
          }
        rescue Aws::EC2::Errors::ServiceError => e
          handle_aws_error(e)
        end
      end

      def attach_volume(volume_id, instance_id, device: nil)
        log_operation("attach_volume", volume_id: volume_id, instance_id: instance_id, device: device)

        begin
          device ||= next_available_device(instance_id)

          ec2_client.attach_volume(
            volume_id: volume_id,
            instance_id: instance_id,
            device: device
          )

          {
            success: true,
            device: device,
            status: "attaching"
          }
        rescue Aws::EC2::Errors::ServiceError => e
          handle_aws_error(e)
        end
      end

      def detach_volume(volume_id, force: false)
        log_operation("detach_volume", volume_id: volume_id, force: force)

        begin
          ec2_client.detach_volume(
            volume_id: volume_id,
            force: force
          )

          { success: true }
        rescue Aws::EC2::Errors::ServiceError => e
          handle_aws_error(e)
        end
      end

      def delete_volume(volume_id)
        log_operation("delete_volume", volume_id: volume_id)

        begin
          ec2_client.delete_volume(volume_id: volume_id)
          { success: true }
        rescue Aws::EC2::Errors::ServiceError => e
          handle_aws_error(e)
        end
      end

      def get_volume(volume_id)
        log_operation("get_volume", volume_id: volume_id)

        begin
          response = ec2_client.describe_volumes(volume_ids: [ volume_id ])
          volume = response.volumes.first

          return build_error_response("Volume not found", code: "NotFound") unless volume

          attachment = volume.attachments.first

          {
            success: true,
            volume_id: volume.volume_id,
            size_gb: volume.size,
            volume_type: volume.volume_type,
            status: volume.state,
            attached_to: attachment&.instance_id,
            device: attachment&.device
          }
        rescue Aws::EC2::Errors::ServiceError => e
          handle_aws_error(e)
        end
      end

      # ===========================================
      # Image Operations
      # ===========================================

      def create_image(instance_id, name:, description: nil)
        log_operation("create_image", instance_id: instance_id, name: name)

        begin
          response = ec2_client.create_image(
            instance_id: instance_id,
            name: name,
            description: description || "Created by Powernode",
            no_reboot: false
          )

          {
            success: true,
            image_id: response.image_id,
            status: "pending"
          }
        rescue Aws::EC2::Errors::ServiceError => e
          handle_aws_error(e)
        end
      end

      def get_image(image_id)
        log_operation("get_image", image_id: image_id)

        begin
          response = ec2_client.describe_images(image_ids: [ image_id ])
          image = response.images.first

          return build_error_response("Image not found", code: "NotFound") unless image

          {
            success: true,
            image_id: image.image_id,
            name: image.name,
            description: image.description,
            status: image.state
          }
        rescue Aws::EC2::Errors::ServiceError => e
          handle_aws_error(e)
        end
      end

      def delete_image(image_id)
        log_operation("delete_image", image_id: image_id)

        begin
          ec2_client.deregister_image(image_id: image_id)
          { success: true }
        rescue Aws::EC2::Errors::ServiceError => e
          handle_aws_error(e)
        end
      end

      # ===========================================
      # Utility Methods
      # ===========================================

      def test_connection
        log_operation("test_connection")

        begin
          # Try to describe regions as a connection test
          response = ec2_client.describe_regions

          {
            success: true,
            message: "AWS connection successful",
            provider: "aws",
            region: aws_region,
            available_regions: response.regions.map(&:region_name)
          }
        rescue Aws::EC2::Errors::ServiceError => e
          {
            success: false,
            error: "AWS connection failed: #{e.message}",
            error_code: e.code
          }
        end
      end

      def get_metadata
        {
          provider: "aws",
          region: aws_region,
          features: %w[instances volumes ips images snapshots security_groups vpcs]
        }
      end

      # Cheap, side-effect-free authentication probe used by
      # CredentialValidationService (M2 BYOC). Calls
      # STS#GetCallerIdentity which works with any IAM principal — no
      # EC2-scope permissions required, and never mutates state.
      #
      # Reads credentials from @transient_credentials when set (transient
      # mode via `with_credentials`), otherwise falls back to the
      # connection's typed columns via the BaseProvider credential helper.
      def authenticate?
        @last_authentication_error = nil

        access_key_id     = auth_credential("access_key_id", "access_key")
        secret_access_key = auth_credential("secret_access_key", "secret_key")
        region_name       = auth_credential("region", "default_region") || "us-east-1"

        if access_key_id.to_s.strip.empty?
          @last_authentication_error = "missing access_key_id"
          return false
        end
        if secret_access_key.to_s.strip.empty?
          @last_authentication_error = "missing secret_access_key"
          return false
        end

        sts_client = ::Aws::STS::Client.new(
          region: region_name,
          credentials: ::Aws::Credentials.new(access_key_id, secret_access_key),
          http_open_timeout: DEFAULT_CONNECT_TIMEOUT,
          http_read_timeout: DEFAULT_READ_TIMEOUT
        )
        sts_client.get_caller_identity
        true
      rescue StandardError => e
        @last_authentication_error = e.message
        false
      end

      protected

      def normalize_status(provider_status)
        AWS_STATUS_MAP[provider_status] || "unknown"
      end

      private

      def ec2_client
        @ec2_client ||= Aws::EC2::Client.new(
          region: aws_region,
          credentials: aws_credentials,
          http_open_timeout: DEFAULT_CONNECT_TIMEOUT,
          http_read_timeout: DEFAULT_READ_TIMEOUT
        )
      end

      def aws_credentials
        Aws::Credentials.new(
          credential(column: :access_key, required: true),
          credential(column: :secret_key, required: true)
        )
      end

      def aws_region
        # Region passed at construction wins over fallbacks; the credential
        # helper covers config + sensible default.
        region&.region_code || credential(config_key: "default_region", default: "us-east-1")
      end

      def default_availability_zone
        "#{aws_region}a"
      end

      def describe_instance(instance_id)
        response = ec2_client.describe_instances(instance_ids: [ instance_id ])
        instance = response.reservations.first&.instances&.first

        return build_error_response("Instance not found", code: "NotFound") unless instance

        build_instance_response(
          cloud_id: instance.instance_id,
          status: normalize_status(instance.state.name),
          private_ip: instance.private_ip_address,
          public_ip: instance.public_ip_address,
          instance_type: instance.instance_type
        )
      rescue Aws::EC2::Errors::InvalidInstanceIDNotFound
        build_error_response("Instance not found", code: "NotFound")
      end

      # Materialize an EC2 Security Group from a normalized rule set
      # (see System::IpAllowlistService) and merge its id into
      # params[:security_groups] so build_run_instance_params picks it up.
      #
      # No-op when :security_group_rules is missing or empty — the
      # adapter falls back to whatever :security_groups the caller
      # supplied (or the VPC default group).
      def ensure_allowlist_security_group(params)
        rules = Array(params[:security_group_rules])
        return params if rules.empty?

        sg_name = "powernode-allowlist-#{SecureRandom.hex(4)}"
        sg_response = ec2_client.create_security_group(
          group_name: sg_name,
          description: "Powernode IP allowlist (auto-generated)"
        )

        ec2_client.authorize_security_group_ingress(
          group_id: sg_response.group_id,
          ip_permissions: rules.map { |rule|
            {
              ip_protocol: rule[:protocol] || "tcp",
              from_port: rule[:port],
              to_port: rule[:port],
              ip_ranges: [ {
                cidr_ip: rule[:source],
                description: rule[:description].to_s.slice(0, 255)
              } ]
            }
          }
        )

        merged_groups = Array(params[:security_groups]) + [ sg_response.group_id ]
        params.merge(security_groups: merged_groups)
      rescue Aws::EC2::Errors::ServiceError => e
        # An allowlist SG creation failure must not block provisioning —
        # log and let the caller continue with whatever default groups
        # were already provided. Operators see this in CloudTrail too.
        logger.warn("[AwsProvider] allowlist SG creation failed: #{e.class}: #{e.message}")
        params
      end

      def build_run_instance_params(params)
        run_params = {
          image_id: params[:image_id],
          instance_type: params[:instance_type],
          min_count: 1,
          max_count: 1
        }

        run_params[:key_name] = params[:key_name] if params[:key_name]
        run_params[:security_group_ids] = Array(params[:security_groups]) if params[:security_groups]
        run_params[:subnet_id] = params[:subnet_id] if params[:subnet_id]
        run_params[:user_data] = Base64.encode64(params[:user_data]) if params[:user_data]

        # Idempotency — pass the NodeInstance UUID as the EC2 ClientToken so a
        # lost-response retry (the AWS SDK's default standard retry mode makes up
        # to 3 attempts) dedupes to the SAME billable instance rather than
        # launching a duplicate. The token MUST be stable across retries of the
        # same logical provision, so it is sourced from the per-instance UUID
        # (threaded in via :instance) — never a random value, which would defeat
        # AWS-side deduplication.
        client_token = params[:instance]&.id
        run_params[:client_token] = client_token.to_s if client_token.present?

        # Assemble tags once and pass them via tag_specifications so the
        # instance launches already tagged (atomic with run_instances). The
        # human-readable Name is folded in here rather than applied by a
        # separate post-create create_tags call, which could fail after launch
        # and orphan a running, untagged, billable instance.
        tag_map = {}
        params[:tags].each { |k, v| tag_map[k.to_s] = v.to_s } if params[:tags].present?
        tag_map["Name"] = params[:name].to_s if params[:name].present?

        if tag_map.any?
          run_params[:tag_specifications] = [ {
            resource_type: "instance",
            tags: tag_map.map { |k, v| { key: k, value: v } }
          } ]
        end

        # Block device mappings for root volume
        if params[:root_volume_size]
          run_params[:block_device_mappings] = [ {
            device_name: "/dev/xvda",
            ebs: {
              volume_size: params[:root_volume_size],
              volume_type: params[:root_volume_type] || "gp3",
              delete_on_termination: true
            }
          } ]
        end

        run_params
      end

      def build_ec2_filters(filters)
        ec2_filters = []

        if filters[:status]
          ec2_filters << { name: "instance-state-name", values: [ filters[:status] ] }
        end

        if filters[:instance_ids]
          ec2_filters << { name: "instance-id", values: Array(filters[:instance_ids]) }
        end

        if filters[:tags]
          filters[:tags].each do |key, value|
            ec2_filters << { name: "tag:#{key}", values: [ value ] }
          end
        end

        ec2_filters
      end

      def next_available_device(instance_id)
        # Get current block device mappings
        response = ec2_client.describe_instances(instance_ids: [ instance_id ])
        instance = response.reservations.first&.instances&.first

        return "/dev/sdf" unless instance

        used_devices = instance.block_device_mappings.map(&:device_name)

        # Find next available device letter
        ("f".."p").each do |letter|
          device = "/dev/sd#{letter}"
          return device unless used_devices.include?(device)
        end

        "/dev/sdp"
      end

      def handle_aws_error(error)
        logger.error("[AwsProvider] AWS Error: #{error.class} - #{error.message}")

        case error
        when Aws::EC2::Errors::UnauthorizedOperation
          raise AuthenticationError, "AWS authentication failed: #{error.message}"
        when Aws::EC2::Errors::RequestLimitExceeded
          raise RateLimitError, "AWS rate limit exceeded: #{error.message}"
        when Aws::EC2::Errors::InvalidInstanceIDNotFound,
             Aws::EC2::Errors::InvalidVolumeNotFound,
             Aws::EC2::Errors::InvalidAMIIDNotFound
          raise ResourceNotFoundError, error.message
        when Aws::EC2::Errors::InstanceLimitExceeded,
             Aws::EC2::Errors::InsufficientInstanceCapacity
          raise QuotaExceededError, error.message
        else
          build_error_response(error.message, code: error.code)
        end
      end
    end
  end
end
