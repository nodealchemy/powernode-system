# frozen_string_literal: true

module System
  # Service for managing PXE/Netboot configuration for physical instances
  # Handles TFTP and DHCP configuration for network booting
  class NetbootService
    class NetbootError < StandardError; end

    TFTP_ROOT = ENV.fetch("NETBOOT_TFTP_ROOT", "/srv/tftp")
    PXELINUX_CFG_DIR = File.join(TFTP_ROOT, "pxelinux.cfg")

    # iPXE template path. The template renders the per-instance iPXE
    # chainload script with the bootstrap token, CA, and instance UUID
    # baked into the kernel cmdline so first-boot enrollment is one
    # round-trip from physical hardware to enrolled-and-running.
    # Reference: Golden Eclipse plan M3 — images/ipxe.
    IPXE_TEMPLATE_PATH = File.expand_path(
      "../../../../initramfs/images/ipxe/template.ipxe.erb",
      __dir__
    )

    # Sync netboot configuration for an instance
    #
    # @param instance [System::NodeInstance] The physical instance
    # @return [Hash] Result with :success, :error
    def self.sync(instance:)
      new.sync(instance: instance)
    end

    # Enable netboot for an instance
    #
    # @param instance [System::NodeInstance] The physical instance
    # @param options [Hash] Netboot options
    # @return [Hash] Result with :success, :error
    def self.enable(instance:, options: {})
      new.enable(instance: instance, options: options)
    end

    # Disable netboot for an instance
    #
    # @param instance [System::NodeInstance] The physical instance
    # @return [Hash] Result with :success, :error
    def self.disable(instance:)
      new.disable(instance: instance)
    end

    # Render an iPXE chainload script for a given NodeInstance. Used by the
    # bare-metal/PXE path: physical hardware DHCP-options-67's into the
    # platform's iPXE endpoint, which calls this method and returns the
    # script as text. iPXE then chains kernel + initramfs + boots.
    #
    # @param instance [System::NodeInstance]
    # @param bootstrap_token [String] single-use plaintext token
    # @param image_base [String] absolute URL prefix for kernel/initrd
    # @param ca_pem_url [String, nil] preferred when CA chain >1 cert
    # @param ca_pem_inline [String, nil] fallback for inline CA in cmdline
    # @return [String] rendered iPXE script
    def self.render_ipxe_script(instance:, bootstrap_token:, image_base:,
                                ca_pem_url: nil, ca_pem_inline: nil)
      new.render_ipxe_script(
        instance: instance,
        bootstrap_token: bootstrap_token,
        image_base: image_base,
        ca_pem_url: ca_pem_url,
        ca_pem_inline: ca_pem_inline
      )
    end

    def render_ipxe_script(instance:, bootstrap_token:, image_base:,
                           ca_pem_url: nil, ca_pem_inline: nil)
      validate_instance!(instance)
      raise NetbootError, "bootstrap_token required" if bootstrap_token.blank?
      raise NetbootError, "image_base required" if image_base.blank?
      raise NetbootError, "iPXE template missing at #{IPXE_TEMPLATE_PATH}" unless File.exist?(IPXE_TEMPLATE_PATH)

      template_src = File.read(IPXE_TEMPLATE_PATH)
      bind_ctx = IpxeRenderContext.new(
        instance_uuid: instance.id,
        bootstrap_token: bootstrap_token,
        ca_pem_url: ca_pem_url,
        ca_pem_inline: ca_pem_inline,
        image_base: image_base
      ).get_binding
      ERB.new(template_src, trim_mode: "-").result(bind_ctx)
    end

    # Internal context object so ERB has access to a clean variable
    # surface — avoids leaking accidental ivars from the service into the
    # template.
    class IpxeRenderContext
      def initialize(instance_uuid:, bootstrap_token:, ca_pem_url:, ca_pem_inline:, image_base:)
        @instance_uuid = instance_uuid
        @bootstrap_token = bootstrap_token
        @ca_pem_url = ca_pem_url
        @ca_pem_inline = ca_pem_inline
        @image_base = image_base
      end
      attr_reader :instance_uuid, :bootstrap_token, :ca_pem_url, :ca_pem_inline, :image_base

      def get_binding
        binding
      end
    end

    def sync(instance:)
      validate_instance!(instance)

      unless instance.variety == "physical"
        return { success: false, error: "Netboot only available for physical instances" }
      end

      unless netboot_enabled?(instance)
        Rails.logger.info("[NetbootService] Netboot not enabled for #{instance.name}")
        return { success: true, message: "Netboot not enabled" }
      end

      Rails.logger.info("[NetbootService] Syncing netboot for #{instance.name}")

      begin
        # Generate PXE configuration
        pxe_config = generate_pxe_config(instance)

        # Write configuration file
        write_pxe_config(instance, pxe_config)

        { success: true }
      rescue StandardError => e
        Rails.logger.error("[NetbootService] Sync failed: #{e.message}")
        { success: false, error: e.message }
      end
    end

    def enable(instance:, options: {})
      validate_instance!(instance)

      unless instance.variety == "physical"
        return { success: false, error: "Netboot only available for physical instances" }
      end

      Rails.logger.info("[NetbootService] Enabling netboot for #{instance.name}")

      begin
        # Update instance config to enable netboot
        config = instance.config || {}
        config["netboot"] = {
          "enabled" => true,
          "boot_type" => options[:boot_type] || "localboot",
          "kernel" => options[:kernel],
          "initrd" => options[:initrd],
          "append" => options[:append]
        }

        instance.update!(config: config)

        # Generate and write PXE configuration
        pxe_config = generate_pxe_config(instance)
        write_pxe_config(instance, pxe_config)

        { success: true }
      rescue StandardError => e
        Rails.logger.error("[NetbootService] Enable failed: #{e.message}")
        { success: false, error: e.message }
      end
    end

    def disable(instance:)
      validate_instance!(instance)

      Rails.logger.info("[NetbootService] Disabling netboot for #{instance.name}")

      begin
        # Update instance config to disable netboot
        config = instance.config || {}
        config["netboot"] ||= {}
        config["netboot"]["enabled"] = false

        instance.update!(config: config)

        # Remove PXE configuration file
        remove_pxe_config(instance)

        { success: true }
      rescue StandardError => e
        Rails.logger.error("[NetbootService] Disable failed: #{e.message}")
        { success: false, error: e.message }
      end
    end

    private

    def validate_instance!(instance)
      raise ArgumentError, "Instance required" unless instance
      raise ArgumentError, "Instance must be a System::NodeInstance" unless instance.is_a?(::System::NodeInstance)
    end

    def netboot_enabled?(instance)
      instance.config&.dig("netboot", "enabled") == true
    end

    def generate_pxe_config(instance)
      netboot_config = instance.config&.dig("netboot") || {}
      boot_type = netboot_config["boot_type"] || "localboot"

      case boot_type
      when "localboot"
        generate_localboot_config(instance)
      when "install"
        generate_install_config(instance, netboot_config)
      when "rescue"
        generate_rescue_config(instance, netboot_config)
      when "custom"
        generate_custom_config(instance, netboot_config)
      else
        generate_localboot_config(instance)
      end
    end

    def generate_localboot_config(instance)
      <<~PXECONFIG
        # PXE configuration for #{instance.name}
        # Generated at #{Time.current}
        DEFAULT local
        PROMPT 0
        TIMEOUT 0
        LABEL local
          LOCALBOOT 0
      PXECONFIG
    end

    def generate_install_config(instance, config)
      kernel = config["kernel"] || "vmlinuz"
      initrd = config["initrd"] || "initrd.img"
      append = config["append"] || ""

      architecture = instance.node&.node_template&.node_platform&.node_architecture

      <<~PXECONFIG
        # PXE configuration for #{instance.name}
        # Generated at #{Time.current}
        DEFAULT install
        PROMPT 0
        TIMEOUT 100
        LABEL install
          KERNEL #{kernel}
          APPEND initrd=#{initrd} #{append}
      PXECONFIG
    end

    def generate_rescue_config(instance, config)
      kernel = config["kernel"] || "rescue/vmlinuz"
      initrd = config["initrd"] || "rescue/initrd.img"

      <<~PXECONFIG
        # PXE configuration for #{instance.name} (RESCUE MODE)
        # Generated at #{Time.current}
        DEFAULT rescue
        PROMPT 0
        TIMEOUT 100
        LABEL rescue
          KERNEL #{kernel}
          APPEND initrd=#{initrd} rescue
      PXECONFIG
    end

    def generate_custom_config(instance, config)
      config["pxe_config"] || generate_localboot_config(instance)
    end

    def pxe_config_filename(instance)
      # PXE configuration files are named based on MAC address or IP
      # Format: 01-xx-xx-xx-xx-xx-xx (MAC) or IP in hex

      if instance.private_ip_address.present?
        # Convert IP to hex format for PXE
        ip_hex = instance.private_ip_address.split(".").map { |o| o.to_i.to_s(16).upcase.rjust(2, "0") }.join
        ip_hex
      else
        # Use instance ID as fallback
        "instance-#{instance.id}"
      end
    end

    def write_pxe_config(instance, config)
      return unless pxe_enabled?

      FileUtils.mkdir_p(PXELINUX_CFG_DIR)

      filename = pxe_config_filename(instance)
      config_path = File.join(PXELINUX_CFG_DIR, filename)

      File.write(config_path, config)
      Rails.logger.info("[NetbootService] Wrote PXE config to #{config_path}")
    end

    def remove_pxe_config(instance)
      return unless pxe_enabled?

      filename = pxe_config_filename(instance)
      config_path = File.join(PXELINUX_CFG_DIR, filename)

      if File.exist?(config_path)
        File.delete(config_path)
        Rails.logger.info("[NetbootService] Removed PXE config #{config_path}")
      end
    end

    def pxe_enabled?
      # Check if PXE/TFTP is configured
      ENV["NETBOOT_ENABLED"] == "true"
    end
  end
end
