# frozen_string_literal: true

require "open3"
require "fileutils"
require "tmpdir"

module System
  # Builds bootable images and stores them via the platform's
  # FileManagement::Object — gaining versioning, multi-backend storage
  # (S3/GCS/Azure/NFS/SMB/local), checksums, and access control for free.
  #
  # Two modes:
  #   - Cloud: ask a provider to image a running cloud instance (returns
  #     the cloud-side image_id; bytes stay in the cloud account).
  #   - Local: synthesize an image locally via dd / qemu-img / mkisofs,
  #     then upload to FileManagement and link it back to the architecture.
  #
  # Returns System::Runtime::Result.
  class ImageCreationService
    class ImageError < StandardError; end
    class MissingBinaryError < ImageError; end

    SUPPORTED_FORMATS = %w[img iso qcow2 ami vmdk].freeze

    # Required system binaries per format. Verified at call time so we fail
    # loudly if the host is missing them rather than silently returning
    # success (audit S3/M6).
    REQUIRED_BINARIES = {
      "img"   => %w[dd],
      "iso"   => %w[mkisofs],            # alternate: genisoimage
      "qcow2" => %w[qemu-img],
      "ami"   => %w[dd],                 # ami = raw with cloud-init layout
      "vmdk"  => %w[qemu-img]
    }.freeze

    # ===========================================
    # Public API — instance-side (cloud images)
    # ===========================================

    def self.create_from_instance(instance:, name:, description: nil, options: {})
      new.create_from_instance(instance: instance, name: name, description: description, options: options)
    end

    def self.get_image_status(instance:, image_id:)
      new.get_image_status(instance: instance, image_id: image_id)
    end

    def self.delete_image(instance:, image_id:)
      new.delete_image(instance: instance, image_id: image_id)
    end

    def self.create_from_architecture(architecture:, format: "img", options: {})
      new.create_from_architecture(architecture: architecture, format: format, options: options)
    end

    def create_from_instance(instance:, name:, description: nil, options: {})
      validate_instance!(instance)

      return Runtime::Result.err(error: "Instance has no cloud instance ID") unless instance.cloud_instance_id.present?

      Rails.logger.info("[ImageCreationService] Creating image from instance #{instance.name}")

      Providers::Registry.with_adapter(instance: instance) do |adapter|
        cloud_result = adapter.create_image(instance.cloud_instance_id, name: name, description: description)

        if cloud_result[:success]
          remember_cloud_image(instance, name, cloud_result)
          Runtime::Result.ok(data: { image_id: cloud_result[:image_id], status: cloud_result[:status] })
        else
          Runtime::Result.err(error: cloud_result[:error])
        end
      end
    rescue Providers::BaseProvider::ProviderError => e
      Rails.logger.error("[ImageCreationService] Provider error: #{e.message}")
      Runtime::Result.err(error: e.message)
    rescue ArgumentError
      raise
    rescue StandardError => e
      Rails.logger.error("[ImageCreationService] create_from_instance failed: #{e.message}")
      Runtime::Result.err(error: e.message)
    end

    def get_image_status(instance:, image_id:)
      validate_instance!(instance)

      Providers::Registry.with_adapter(instance: instance) do |adapter|
        result = adapter.get_image(image_id)
        if result[:success]
          Runtime::Result.ok(data: result.except(:success))
        else
          Runtime::Result.err(error: result[:error])
        end
      end
    rescue Providers::BaseProvider::ProviderError => e
      Runtime::Result.err(error: e.message)
    end

    def delete_image(instance:, image_id:)
      validate_instance!(instance)

      Providers::Registry.with_adapter(instance: instance) do |adapter|
        result = adapter.delete_image(image_id)
        if result[:success]
          forget_cloud_image(instance, image_id)
          Runtime::Result.ok
        else
          Runtime::Result.err(error: result[:error])
        end
      end
    rescue Providers::BaseProvider::ProviderError => e
      Runtime::Result.err(error: e.message)
    end

    # ===========================================
    # Public API — architecture-side (local image synthesis)
    # ===========================================

    def create_from_architecture(architecture:, format: "img", options: {})
      validate_architecture!(architecture)

      format = format.to_s.downcase
      unless SUPPORTED_FORMATS.include?(format)
        return Runtime::Result.err(error: "Unsupported image format: #{format}")
      end

      missing = missing_binaries(format)
      if missing.any?
        return Runtime::Result.err(
          error: "Missing required binaries for #{format}: #{missing.join(', ')}. Install on the platform host before creating images."
        )
      end

      Rails.logger.info("[ImageCreationService] Creating #{format} image from architecture #{architecture.name}")

      Dir.mktmpdir("image-#{format}-") do |tmpdir|
        local_path = File.join(tmpdir, build_filename(architecture, format))

        size_bytes = case format
        when "img"   then build_raw_image(local_path, options)
        when "iso"   then build_iso_image(architecture, local_path, options)
        when "qcow2" then build_qcow2_image(local_path, options)
        when "ami"   then build_ami_image(local_path, options)
        when "vmdk"  then build_vmdk_image(local_path, options)
        end

        upload_result = upload_image(architecture, local_path, format, size_bytes, options)
        return upload_result unless upload_result.success?

        file_object = upload_result.data[:file_object]
        link_to_architecture(architecture, file_object, options)

        Runtime::Result.ok(data: {
          file_object_id: file_object.id,
          filename: file_object.filename,
          size_bytes: file_object.file_size,
          format: format,
          checksum_sha256: file_object.checksum_sha256
        })
      end
    rescue ArgumentError
      raise
    rescue ImageError => e
      Rails.logger.error("[ImageCreationService] #{e.class}: #{e.message}")
      Runtime::Result.err(error: e.message)
    rescue StandardError => e
      Rails.logger.error("[ImageCreationService] create_from_architecture failed: #{e.message}")
      Runtime::Result.err(error: e.message)
    end

    private

    def validate_instance!(instance)
      raise ArgumentError, "Instance required" unless instance
      raise ArgumentError, "Instance must be a System::NodeInstance" unless instance.is_a?(::System::NodeInstance)
    end

    def validate_architecture!(architecture)
      raise ArgumentError, "Architecture required" unless architecture
      raise ArgumentError, "Architecture must be a System::NodeArchitecture" unless architecture.is_a?(::System::NodeArchitecture)
    end

    # ----- Cloud-image bookkeeping (kept on the instance's config blob) -----

    def remember_cloud_image(instance, name, cloud_result)
      config = instance.config || {}
      images = Array(config["created_images"])
      images << {
        "image_id"   => cloud_result[:image_id],
        "name"       => name,
        "created_at" => Time.current.iso8601,
        "status"     => cloud_result[:status]
      }
      instance.update!(config: config.merge("created_images" => images))
    end

    def forget_cloud_image(instance, image_id)
      config = instance.config || {}
      images = Array(config["created_images"]).reject { |img| img["image_id"] == image_id }
      instance.update!(config: config.merge("created_images" => images))
    end

    # ----- Local synthesis primitives — return size_bytes on success -----

    # Raw disk image: zero-filled file at the requested size. `dd` is
    # universal; `fallocate` would be faster on modern Linux but we
    # prefer the broadest compatibility for now.
    def build_raw_image(local_path, options)
      size_mb = (options[:size_mb] || 4096).to_i
      run_or_raise!("dd", "if=/dev/zero", "of=#{local_path}", "bs=1M", "count=#{size_mb}")
      File.size(local_path)
    end

    # ISO 9660 — staging dir gets the architecture's kernel/ramdisk and a
    # minimal isolinux config, then mkisofs spins it into a bootable image.
    # Skips the boot-bits if the architecture has no kernel attached
    # (allows building data-only ISOs).
    def build_iso_image(architecture, local_path, options)
      Dir.mktmpdir("iso-staging-") do |staging|
        copy_arch_boot_files(architecture, staging) if architecture.boot_ready?

        write_isolinux_config(staging, architecture, options) if architecture.boot_ready?

        run_or_raise!(
          "mkisofs",
          "-o", local_path,
          "-J", "-R", # Joliet + Rock Ridge
          "-V", architecture.name.parameterize.upcase[0, 32],
          staging
        )
      end
      File.size(local_path)
    end

    # QCOW2 — sparse, copy-on-write virtual disk image.
    def build_qcow2_image(local_path, options)
      size_gb = (options[:size_gb] || 10).to_i
      run_or_raise!("qemu-img", "create", "-f", "qcow2", local_path, "#{size_gb}G")
      File.size(local_path)
    end

    # AMI-compatible raw image. Same as raw IMG; future iteration could
    # partition + format + install cloud-init for true AMI parity.
    def build_ami_image(local_path, options)
      size_gb = (options[:size_gb] || 8).to_i
      size_mb = size_gb * 1024
      run_or_raise!("dd", "if=/dev/zero", "of=#{local_path}", "bs=1M", "count=#{size_mb}")
      File.size(local_path)
    end

    # VMDK — VMware-compatible disk. qemu-img handles the format.
    def build_vmdk_image(local_path, options)
      size_gb = (options[:size_gb] || 10).to_i
      run_or_raise!("qemu-img", "create", "-f", "vmdk", local_path, "#{size_gb}G")
      File.size(local_path)
    end

    # ----- Upload + linking -----

    # Uploads the local file via FileStorageService (which writes to the
    # account's default storage backend — S3/GCS/local/etc.) and creates
    # a FileManagement::Object. Returns Result wrapping the file_object.
    def upload_image(architecture, local_path, format, _size_bytes, options)
      raise ImageError, "Local image not produced at #{local_path}" unless File.exist?(local_path)

      service = ::FileStorageService.new(architecture.account)
      File.open(local_path, "rb") do |io|
        file_object = service.upload_file(
          io,
          filename: File.basename(local_path),
          content_type: content_type_for(format),
          category: "system",
          visibility: "private",
          metadata: {
            "source_architecture_id" => architecture.id,
            "image_format"           => format,
            "built_at"               => Time.current.iso8601
          },
          uploaded_by_id: options[:uploaded_by_id]
        )
        Runtime::Result.ok(data: { file_object: file_object })
      end
    rescue ::FileStorageService::QuotaExceededError => e
      Runtime::Result.err(error: "Storage quota exceeded: #{e.message}")
    rescue ::FileStorageService::StorageNotFoundError => e
      Runtime::Result.err(error: "No file storage configured for account: #{e.message}")
    rescue StandardError => e
      Runtime::Result.err(error: "Image upload failed: #{e.message}")
    end

    # Optionally update the architecture's kernel/ramdisk/image FK based
    # on options[:link_as] ("kernel", "ramdisk", "image"). When unset we
    # don't auto-link — caller may want the bytes available for download
    # without changing the architecture's bootable image.
    def link_to_architecture(architecture, file_object, options)
      column = case options[:link_as].to_s
      when "kernel"  then :kernel_file_object_id
      when "ramdisk" then :ramdisk_file_object_id
      when "image"   then :image_file_object_id
      else nil
      end
      return unless column

      architecture.update!(column => file_object.id)
    end

    # ----- Helpers -----

    def copy_arch_boot_files(architecture, staging)
      [
        [ architecture.kernel_file_object,  "vmlinuz" ],
        [ architecture.ramdisk_file_object, "initrd.img" ],
        [ architecture.image_file_object,   "rootfs.img" ]
      ].each do |file_object, dest_name|
        next unless file_object

        # Stream the FileManagement::Object's bytes into the staging dir
        # so mkisofs has a real local file to layer in.
        File.open(File.join(staging, dest_name), "wb") do |out|
          out.write(file_object.read)
        end
      end
    end

    def write_isolinux_config(staging, architecture, options)
      cfg = <<~CFG
        DEFAULT linux
        TIMEOUT 50
        PROMPT 1
        LABEL linux
          KERNEL vmlinuz
          INITRD initrd.img
          APPEND #{architecture.kernel_options || options[:kernel_options] || ''}
      CFG
      File.write(File.join(staging, "isolinux.cfg"), cfg)
    end

    # Run an external command and raise if it exits non-zero. Surfaces
    # stderr in the exception so the operator sees what dd/qemu-img/mkisofs
    # actually said.
    def run_or_raise!(*cmd)
      stdout, stderr, status = Open3.capture3(*cmd)
      return stdout if status.success?

      raise ImageError,
            "#{cmd.first} failed (exit #{status.exitstatus}): #{stderr.strip[0, 500]}"
    end

    # Returns binaries declared in REQUIRED_BINARIES that aren't on PATH.
    def missing_binaries(format)
      Array(REQUIRED_BINARIES[format]).reject do |bin|
        system("which", bin, out: File::NULL, err: File::NULL)
      end
    end

    def build_filename(architecture, format)
      "#{architecture.name.parameterize}-#{Time.current.strftime('%Y%m%d%H%M%S')}.#{format}"
    end

    def content_type_for(format)
      case format
      when "img", "ami" then "application/octet-stream"
      when "iso"        then "application/x-iso9660-image"
      when "qcow2"      then "application/x-qemu-disk"
      when "vmdk"       then "application/x-vmdk"
      else "application/octet-stream"
      end
    end
  end
end
