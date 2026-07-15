# frozen_string_literal: true

module System
  # Computes the set of package NAMES a base-OS module (default
  # base-os-ubuntu-noble) already ships — i.e. the resolved dependency
  # closure of that module's own package_spec. The PackageModuleMaterializer
  # uses this to EXCLUDE those packages when materializing an on-demand
  # package closure: materializing `nginx` must not spawn its own per-package
  # libc6/coreutils/... modules (base-os already provides them, and each one
  # would add a lowerdir layer), and must instead carry a single synthetic
  # `requires: base-os` edge — the exact shape campaign 019f6084 inc1
  # established for hand-authored modules (`requires: capability:os.userland`,
  # which ManifestImportService stores as a plain requires ModuleDependency
  # row from the module to base-os).
  #
  # DESIGN — how the baseline is sourced (documented tradeoff):
  #   The baseline is the closure of the base-OS NodeModule's package_spec
  #   resolved through the SAME System::PackageDependencyResolver + the SAME
  #   repository the target package is being materialized from. This reuses
  #   the existing resolver (no build required, no second data source) and is
  #   deterministic for a given repository sync — the cache is keyed on the
  #   repository's last_synced_at so a re-sync recomputes.
  #
  #   Tradeoff: base-os is actually built (in CI, via mmdebstrap) against the
  #   Ubuntu archive. When the materializer's repository IS that archive (the
  #   overwhelmingly common case) the resolved baseline is faithful. When a
  #   caller materializes from a third-party repo that does NOT itself carry
  #   base-os's packages (e.g. a bare nginx.org apt repo), those roots simply
  #   won't resolve there and the baseline shrinks to what that repo can see —
  #   a graceful degradation (we exclude what we can positively identify as
  #   baseline within the same repo set), never an error. The
  #   `include_baseline: true` escape hatch on the materializer bypasses this
  #   entirely for building against a non-Powernode base.
  #
  #   When no base-OS module exists on the account, the baseline is empty and
  #   exclusion is a no-op (full closure — pre-inc2 behavior).
  class BaseOsBaselineResolver
    DEFAULT_BASE_OS_MODULE = "base-os-ubuntu-noble"
    CACHE_TTL = 1.hour

    Result = Struct.new(:base_os_module, :package_names, keyword_init: true) do
      def present?
        base_os_module.present?
      end
    end

    def self.call(**kwargs)
      new(**kwargs).call
    end

    # @param repository [System::PackageRepository] the repo the target is
    #   materialized from — the baseline is resolved through the same repo.
    # @param architecture [String] kind-specific arch (already translated by
    #   the caller, e.g. "amd64"/"x86_64").
    # @param account [Account]
    # @param base_os_module_name [String]
    def initialize(repository:, architecture:, account:, base_os_module_name: DEFAULT_BASE_OS_MODULE)
      @repository          = repository
      @architecture        = architecture
      @account             = account
      @base_os_module_name = base_os_module_name.presence || DEFAULT_BASE_OS_MODULE
    end

    def call
      base_os = find_base_os_module
      return Result.new(base_os_module: nil, package_names: Set.new) unless base_os

      Result.new(base_os_module: base_os, package_names: cached_package_names(base_os))
    end

    private

    def find_base_os_module
      ::System::NodeModule.find_by(account_id: @account.id, name: @base_os_module_name)
    end

    # Per-(base_os, repo, arch, sync) cache so repeated materializations against
    # the same synced repo don't re-walk the whole base-os closure each time.
    def cached_package_names(base_os)
      key    = cache_key(base_os)
      cached = ::Rails.cache.read(key)
      return Set.new(cached) if cached

      names = compute_package_names(base_os)
      ::Rails.cache.write(key, names.to_a, expires_in: CACHE_TTL)
      names
    end

    def cache_key(base_os)
      snapshot = @repository.last_synced_at&.to_i || 0
      [ "system/base_os_baseline", base_os.id, @repository.id, @architecture, snapshot ].join(":")
    end

    # Resolve each root package in base-os's package_spec through the shared
    # resolver + union the names of every package in each closure.
    def compute_package_names(base_os)
      resolver = ::System::PackageDependencyResolver.new(
        repositories: [ @repository ], architecture: @architecture
      )
      root_package_names(base_os).each_with_object(Set.new) do |root, names|
        result = resolver.resolve(root_package_name: root)
        result.packages.each { |pkg| names << pkg.name }
      end
    end

    def root_package_names(base_os)
      base_os.package_spec_text.to_s.split(/\r?\n/).map(&:strip).reject(&:blank?)
    end
  end
end
