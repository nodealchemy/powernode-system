# frozen_string_literal: true

module System
  # Loads platform-module manifests (extensions/system/modules/<name>/manifest.yaml)
  # for the powernode_platform_modules seed and anything else that needs the
  # canonical catalog. Single source of truth shared with the M1 supply chain
  # (build-platform-modules.yaml reads the same files).
  module PlatformModuleManifestLoader
    module_function

    DEFAULT_ROOT = ::Rails.root.join("..", "extensions", "system", "modules").to_s.freeze

    def load_from_disk(root: DEFAULT_ROOT)
      unless ::Dir.exist?(root)
        raise "Platform modules disk root missing: #{root}. " \
              "Create extensions/system/modules/<name>/manifest.yaml for each platform module."
      end

      tracked = git_tracked_dirs(root)

      manifests = {}
      ::Dir.entries(root).sort.each do |entry|
        next if entry.start_with?(".")

        # Resurrection-debris guard (F7-03): untracked dirs restored by the
        # cloud-sync must never re-enter the catalog. Only filter when git
        # tracking info is available — tarball deployments read unfiltered.
        if tracked && !tracked.include?(entry)
          ::Rails.logger.warn("[PlatformModuleManifestLoader] Skipping untracked module dir: #{entry}")
          next
        end

        mfpath = ::File.join(root, entry, "manifest.yaml")
        next unless ::File.file?(mfpath)

        manifests[entry] = ::File.read(mfpath)
      end
      raise "No platform module manifests found under #{root}" if manifests.empty?

      manifests
    end

    # Directory names under modules/ that git knows about, or nil when git
    # tracking info is unavailable (no git binary, not a work tree).
    def git_tracked_dirs(root)
      out = ::IO.popen([ "git", "-C", root.to_s, "ls-files", "-z", "--", "." ], err: ::File::NULL, &:read)
      return nil unless $?.success? && !out.empty?

      out.split("\0").filter_map { |path| path.split("/", 2).first if path.include?("/") }.to_set
    rescue ::SystemCallError, ::IOError
      nil
    end
  end
end
