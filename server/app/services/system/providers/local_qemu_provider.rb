# frozen_string_literal: true

module System
  module Providers
    # Local QEMU/libvirt provider — the M4 thin slice target. Provisions
    # NodeInstances on the operator's local libvirt daemon (or any reachable
    # libvirt URI) using the M3 boot artifacts.
    #
    # Adapter pattern (consistent with InternalCaService, ModuleOciIngestService,
    # ModuleBuildDispatchService, mount.Runner):
    #
    #   POWERNODE_LIBVIRT_MODE=real     → LibvirtRunner (shells to virsh)
    #   POWERNODE_LIBVIRT_MODE=local    → RecorderRunner (test/dev; records calls)
    #   POWERNODE_LIBVIRT_MODE=disabled → returns 503-ish errors immediately
    #
    # Reference: Golden Eclipse plan M4 — local_qemu_provider.
    class LocalQemuProvider < BaseProvider
      DEFAULT_LIBVIRT_URI = ENV.fetch("POWERNODE_LIBVIRT_URI", "qemu:///system")

      def provider_type
        "local_qemu"
      end

      # Provision a domain from a NodeInstance + Template's image artifacts.
      # Returns the BaseProvider-shape instance hash so ProvisioningService
      # can normalize transitions just like cloud paths.
      def create_instance(params)
        log_operation("create_instance", params: params.except(:cloud_init_userdata))

        domain_name = params[:name].to_s.presence || "powernode-#{SecureRandom.hex(4)}"
        instance_record = params[:instance]
        return build_error_response("instance: required") unless instance_record

        # Resolve fw-cfg seed (bootstrap token + ca + image_base + uuid).
        seed = LocalQemu::CloudSeed.build(instance: instance_record,
                                          options: params[:options] || {})

        xml = LocalQemu::DomainXmlBuilder.build(
          instance: instance_record,
          domain_name: domain_name,
          fw_cfg_entries: seed[:fw_cfg_entries],
          arch: params[:arch] || resolve_arch(instance_record),
          memory_mb: params[:memory_mb] || 2048,
          vcpus: params[:vcpus] || 2,
          image_base: seed[:image_base]
        )

        runner = self.class.runner
        define_result = runner.define_domain!(xml: xml, name: domain_name)
        return build_error_response("define failed: #{define_result[:error]}") unless define_result[:ok]

        start_result = runner.start_domain!(name: domain_name)
        return build_error_response("start failed: #{start_result[:error]}") unless start_result[:ok]

        build_instance_response(
          cloud_id: domain_name,
          status: "starting",
          private_ip: nil,  # libvirt DHCP populates async; pulled by sync_status
          public_ip: nil,
          libvirt_uri: DEFAULT_LIBVIRT_URI,
          bootstrap_token_id: seed[:bootstrap_token_id]
        )
      end

      def terminate_instance(instance_id)
        log_operation("terminate_instance", domain: instance_id)
        runner = self.class.runner
        runner.destroy_domain!(name: instance_id) # best-effort; ignores already-stopped
        result = runner.undefine_domain!(name: instance_id)
        if result[:ok]
          { success: true, status: "terminated", cloud_instance_id: instance_id, provider_type: provider_type }
        else
          build_error_response("undefine failed: #{result[:error]}")
        end
      end

      def start_instance(instance_id)
        runner = self.class.runner
        result = runner.start_domain!(name: instance_id)
        return build_error_response(result[:error]) unless result[:ok]
        build_instance_response(cloud_id: instance_id, status: "starting")
      end

      def stop_instance(instance_id, force: false)
        runner = self.class.runner
        result = force ? runner.destroy_domain!(name: instance_id) : runner.shutdown_domain!(name: instance_id)
        return build_error_response(result[:error]) unless result[:ok]
        build_instance_response(cloud_id: instance_id, status: "stopping")
      end

      def reboot_instance(instance_id)
        runner = self.class.runner
        result = runner.reboot_domain!(name: instance_id)
        return build_error_response(result[:error]) unless result[:ok]
        build_instance_response(cloud_id: instance_id, status: "rebooting")
      end

      def get_instance(instance_id)
        runner = self.class.runner
        result = runner.dominfo!(name: instance_id)
        return build_error_response(result[:error]) unless result[:ok]
        build_instance_response(
          cloud_id: instance_id,
          status: normalize_status(result[:state]),
          private_ip: result[:private_ip],
          public_ip: nil
        )
      end

      def list_instances(filters = {})
        runner = self.class.runner
        result = runner.list_domains!
        instances = Array(result[:domains]).map do |d|
          build_instance_response(cloud_id: d[:name], status: normalize_status(d[:state]))
        end
        { success: true, instances: instances, page_count: 1, truncated: false }
      end

      def test_connection
        runner = self.class.runner
        result = runner.uri_check!
        if result[:ok]
          { success: true, message: "libvirt reachable: #{result[:uri]}" }
        else
          { success: false, message: "libvirt unreachable: #{result[:error]}" }
        end
      end

      def get_metadata
        {
          provider_type: "local_qemu",
          libvirt_uri: DEFAULT_LIBVIRT_URI,
          supported_archs: %w[amd64 arm64],
          features: %w[direct_kernel_boot fw_cfg_seed pre_baked_qcow2]
        }
      end

      protected

      def normalize_status(libvirt_state)
        case libvirt_state.to_s.downcase
        when "running"               then STATUSES[:running]
        when "shut off", "shutdown"  then STATUSES[:stopped]
        when "paused", "pmsuspended" then STATUSES[:stopped]
        when "in shutdown"           then STATUSES[:stopping]
        when "crashed"               then STATUSES[:failed]
        else                              STATUSES[:unknown]
        end
      end

      private

      def resolve_arch(instance)
        arch_name = instance.architecture ||
          instance.node&.node_template&.node_platform&.node_architecture&.name
        case arch_name.to_s.downcase
        when "x86_64", "amd64" then "amd64"
        when "aarch64", "arm64" then "arm64"
        else "amd64"
        end
      end

      class << self
        # Singleton runner. Resets between specs via `.reset_runner!` so
        # RecorderRunner can be replaced cleanly.
        def runner
          @runner ||= build_runner
        end

        def reset_runner!
          @runner = nil
        end

        def runner=(custom)
          @runner = custom
        end

        private

        def build_runner
          mode = ENV.fetch("POWERNODE_LIBVIRT_MODE", Rails.env.production? ? "real" : "local")
          case mode
          when "real"     then LocalQemu::LibvirtRunner.new
          when "local"    then LocalQemu::RecorderRunner.new
          when "disabled" then LocalQemu::DisabledRunner.new
          else raise "Unknown POWERNODE_LIBVIRT_MODE=#{mode}"
          end
        end
      end
    end
  end
end
