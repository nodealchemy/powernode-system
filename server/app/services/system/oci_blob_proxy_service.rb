# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require "base64"
require "digest"
require "fileutils"
require "securerandom"

module System
  # Proxies OCI artifact composefs-blob downloads from the upstream
  # registry (Gitea container registry at git.ipnode.org today) to
  # on-node agents. The agent's existing oci.Puller streams from the
  # URL returned by /api/v1/system/node_api/modules/:id/download —
  # this service is the backing implementation that actually fetches
  # the composefs layer.
  #
  # Design choices:
  #
  # - **Cache-by-digest**: blobs land at
  #   `<CACHE_ROOT>/<sha256>.cfs` (immutable on disk). Repeat reconciles
  #   for the same digest are zero-network. Cache eviction is the
  #   operator's concern; nothing here ever deletes.
  #
  # - **Concurrency safety**: a flock-based lock per digest prevents
  #   two simultaneous requests for the same artifact from racing on
  #   the same tmp file. Lock is released as soon as the rename succeeds.
  #
  # - **Verification**: every fetch validates (a) HTTP Content-Length
  #   matches the manifest layer size, (b) bytes written match expected
  #   size, (c) streamed sha256 matches the manifest digest. Any
  #   mismatch fails the request AND deletes the tmp file. A truncated
  #   blob never reaches the cache path.
  #
  # - **Auth**: HTTP Basic with username + access_token. Username comes
  #   from (in order): credential.external_username (preferred —
  #   discovered + persisted), POWERNODE_REGISTRY_USERNAME env var
  #   (operator override), or auto-discovery via Gitea `/api/v1/user`.
  #   Auto-discovery persists the result back to the credential so the
  #   next request short-circuits.
  #
  # - **Index manifests**: when the upstream serves an OCI index manifest
  #   (multi-arch), we recurse into the per-arch image manifest matching
  #   the supplied architecture (default amd64 — matching the platform's
  #   System::ModuleArtifact::SUPPORTED_ARCHITECTURES default order).
  #
  # - **Telemetry**: emits FleetEvent records on cache miss + on pull
  #   failures so operators can audit what crossed the wire.
  #
  # NOT implemented here (tracked separately):
  #
  # - Cosign signature verification (the agent-side Verifier interface
  #   handles this; this service is a transport, not a trust root).
  # - Garbage collection of stale cache entries.
  # - Multiple-credential support per provider (we use the first
  #   active Devops::GitProviderCredential).
  class OciBlobProxyService
    class PullError < StandardError; end
    class AuthError < PullError; end
    class ManifestError < PullError; end
    class VerificationError < PullError; end

    CACHE_ROOT = ENV.fetch("POWERNODE_OCI_CACHE_DIR", "/var/lib/powernode/oci-cache").freeze
    MANIFEST_IMAGE_TYPES = %w[
      application/vnd.oci.image.manifest.v1+json
      application/vnd.docker.distribution.manifest.v2+json
    ].freeze
    MANIFEST_INDEX_TYPES = %w[
      application/vnd.oci.image.index.v1+json
      application/vnd.docker.distribution.manifest.list.v2+json
    ].freeze
    MANIFEST_ACCEPT = (MANIFEST_IMAGE_TYPES + MANIFEST_INDEX_TYPES).join(", ").freeze
    DEFAULT_ARCH = "amd64"
    HTTP_OPEN_TIMEOUT = 10
    HTTP_READ_TIMEOUT = 300
    BLOB_BUFFER_BYTES = 65_536

    # @param oci_ref [String]
    # @param media_type [String] the layer mediaType to extract from the
    #   image manifest (e.g. "application/vnd.powernode.erofs"). Only
    #   consulted when `digest:` is not supplied — the digest path
    #   bypasses the manifest entirely.
    # @param digest [String, nil] sha256 digest of the layer to pull.
    #   When set, skip the manifest fetch and pull directly from
    #   /v2/<repo>/blobs/<digest>. The platform's stored oci_digest
    #   (from artifacts JSONB) is the canonical caller. Avoids the
    #   tag-race where mmdebstrap CI republishes a tag with new bytes
    #   between the time the platform recorded the digest and the
    #   agent's pull — blobs are content-addressable so pulling by
    #   digest can't return the wrong bytes (or the registry is
    #   broken). With/without sha256: prefix both accepted.
    # @param size [Integer, nil] expected blob size in bytes. Used by
    #   the digest path for an additional sanity check; when nil the
    #   service trusts the sha256 verification alone.
    # @param architecture [String, nil] preferred arch when the upstream
    #   serves an index manifest (defaults to "amd64"). Manifest-path only.
    # @param node_module [System::NodeModule, nil] for event context only
    # @param account [Account, nil] for FleetEvent emission scoping
    def initialize(oci_ref:, media_type:, digest: nil, size: nil,
                   architecture: nil, node_module: nil, account: nil)
      raise ArgumentError, "oci_ref required" if oci_ref.to_s.empty?
      raise ArgumentError, "media_type required" if media_type.to_s.empty?
      @oci_ref      = oci_ref
      @media_type   = media_type
      @digest       = digest.presence && normalize_digest(digest)
      @size         = size&.to_i
      @architecture = (architecture || DEFAULT_ARCH).to_s
      @node_module  = node_module
      @account      = account || node_module&.account
    end


    # Returns the local filesystem path of the cached erofs blob.
    # Idempotent: cached path is keyed by layer digest, so repeat calls
    # for the same artifact short-circuit after the first pull.
    #
    # Two modes:
    # - **Digest mode** (preferred): caller supplies @digest at construction.
    #   Skips the manifest fetch and pulls directly from /v2/.../blobs/<digest>.
    #   Bytes are guaranteed to hash to <digest> by registry semantics, so
    #   there's no tag-republish race to worry about.
    # - **Manifest mode** (legacy): caller knows only the tag-form oci_ref.
    #   Fetches manifest, picks the layer matching @media_type, then pulls.
    #   Susceptible to tag-republish races (mmdebstrap CI produces a fresh
    #   blob digest on each rebuild) — prefer digest mode for any caller
    #   that has a stored oci_digest.
    #
    # @return [String] absolute path to the cached .cfs file
    # @raise [PullError] on any failure (network, auth, verification)
    def fetch_blob!
      digest, expected_size = resolve_digest_and_size!
      cached = cache_path_for(digest)

      return cached if cached_complete?(cached, expected_size, digest)

      with_cache_lock(digest) do
        # Re-check after acquiring lock — another request may have
        # populated the cache while we were waiting.
        return cached if cached_complete?(cached, expected_size, digest)

        emit_event(severity: "low", kind: "oci.blob.fetch_start",
                   payload: { module_id: @node_module&.id,
                              oci_ref: @oci_ref, digest: digest,
                              size_bytes: expected_size,
                              mode: @digest ? "digest" : "manifest" })

        stream_blob_to_cache!(digest: digest, target: cached, expected_size: expected_size)

        emit_event(severity: "low", kind: "oci.blob.fetch_complete",
                   payload: { module_id: @node_module&.id,
                              oci_ref: @oci_ref, digest: digest,
                              size_bytes: expected_size, cache_path: cached })
      end
      cached
    rescue StandardError => e
      emit_event(severity: "high", kind: "oci.blob.fetch_failed",
                 payload: { oci_ref: @oci_ref, error: e.message })
      raise
    end

    # Returns [normalized_digest, expected_size]. When the caller supplied
    # @digest at construction time, skip the manifest fetch and trust the
    # caller's pre-stored digest. Otherwise fall back to the manifest path
    # (legacy behavior for callers that only have a tag-form oci_ref).
    #
    # expected_size returns -1 when unknown (digest mode + caller did not
    # pass size); stream_blob_to_cache! treats -1 as "skip the pre-check,
    # rely on sha256 verification of the streamed bytes".
    def resolve_digest_and_size!
      if @digest
        [@digest, @size || -1]
      else
        layer = target_layer!(fetch_image_manifest!)
        [layer.fetch("digest").to_s, layer.fetch("size").to_i]
      end
    end

    # Returns the layer-digest sha256 (with sha256: prefix) without
    # forcing a blob pull. Used by callers that only need to set
    # ETag / digest headers without pre-fetching the blob.
    def layer_digest!
      target_layer!(fetch_image_manifest!).fetch("digest").to_s
    end

    private

    # Fetches the manifest and follows index manifests to the per-arch
    # image manifest. Returns the IMAGE manifest (with a layers array).
    def fetch_image_manifest!
      manifest = fetch_manifest_raw!(reference)
      media = manifest["mediaType"] || manifest["schemaVersion"]
      if MANIFEST_INDEX_TYPES.include?(manifest["mediaType"])
        manifests = Array(manifest["manifests"])
        entry = manifests.find { |m| m.dig("platform", "architecture") == @architecture }
        entry ||= manifests.find { |m| m["mediaType"] && MANIFEST_IMAGE_TYPES.include?(m["mediaType"]) }
        raise ManifestError, "index manifest #{@oci_ref} has no entry for #{@architecture}" unless entry
        return fetch_manifest_raw!(entry["digest"])
      end
      unless MANIFEST_IMAGE_TYPES.include?(manifest["mediaType"])
        # Some registries omit mediaType — accept the layers array if present.
        return manifest if manifest["layers"].is_a?(Array)
        raise ManifestError, "unsupported manifest mediaType #{media.inspect} for #{@oci_ref}"
      end
      manifest
    end

    def fetch_manifest_raw!(ref)
      uri = registry_uri("/v2/#{repo_path}/manifests/#{ref}")
      headers = { "Accept" => MANIFEST_ACCEPT, "Authorization" => basic_auth! }
      resp = http_get(uri, headers: headers)
      unless resp.is_a?(Net::HTTPSuccess)
        raise ManifestError, "manifest fetch #{uri} status #{resp.code}: #{resp.body.to_s[0..200]}"
      end
      JSON.parse(resp.body)
    rescue JSON::ParserError => e
      raise ManifestError, "manifest decode failed: #{e.message}"
    end

    # Finds the layer matching this proxy's @media_type. Same lookup
    # logic for composefs (application/vnd.powernode.composefs) and
    # squashfs (application/vnd.powernode.squashfs) — the layer the
    # CI pushed is what comes back here.
    def target_layer!(manifest)
      layers = Array(manifest["layers"])
      raise ManifestError, "manifest #{@oci_ref} has no layers array" if layers.empty?
      layer = layers.find { |l| l["mediaType"] == @media_type }
      raise ManifestError, "no #{@media_type} layer in manifest #{@oci_ref}" unless layer
      layer
    end

    def stream_blob_to_cache!(digest:, target:, expected_size:)
      FileUtils.mkdir_p(File.dirname(target))
      tmp = "#{target}.tmp.#{SecureRandom.hex(8)}"
      hasher = ::Digest::SHA256.new
      written = 0

      begin
        uri = registry_uri("/v2/#{repo_path}/blobs/#{digest}")
        File.open(tmp, "wb") do |f|
          Net::HTTP.start(uri.host, uri.port,
                          use_ssl: uri.scheme == "https",
                          open_timeout: HTTP_OPEN_TIMEOUT,
                          read_timeout: HTTP_READ_TIMEOUT) do |http|
            req = Net::HTTP::Get.new(uri.request_uri)
            req["Authorization"] = basic_auth!
            http.request(req) do |resp|
              unless resp.is_a?(Net::HTTPSuccess)
                body_preview = resp.body.to_s[0..200] rescue ""
                raise PullError, "blob fetch #{uri} status #{resp.code}: #{body_preview}"
              end
              # expected_size = -1 means "unknown" (digest-mode caller
              # didn't pass size). Skip the Content-Length pre-check in
              # that case — sha256 verification below is sufficient,
              # since matching the digest implies matching the size.
              content_length = resp["Content-Length"]&.to_i
              if expected_size >= 0 && content_length && content_length != expected_size
                raise VerificationError,
                      "Content-Length #{content_length} != expected size #{expected_size} for #{digest}"
              end
              resp.read_body do |chunk|
                f.write(chunk)
                hasher.update(chunk)
                written += chunk.bytesize
              end
            end
          end
        end

        if expected_size >= 0 && written != expected_size
          raise VerificationError, "size mismatch: expected #{expected_size}, wrote #{written}"
        end
        got_digest = "sha256:#{hasher.hexdigest}"
        if got_digest != digest
          raise VerificationError, "digest mismatch: expected #{digest}, got #{got_digest}"
        end

        File.rename(tmp, target)
      ensure
        File.delete(tmp) if File.exist?(tmp)
      end
    end

    def http_get(uri, headers: {})
      Net::HTTP.start(uri.host, uri.port,
                      use_ssl: uri.scheme == "https",
                      open_timeout: HTTP_OPEN_TIMEOUT,
                      read_timeout: HTTP_READ_TIMEOUT) do |http|
        req = Net::HTTP::Get.new(uri.request_uri)
        headers.each { |k, v| req[k] = v }
        http.request(req)
      end
    end

    # expected_size = -1 means "unknown" (digest-mode caller didn't pass
    # size). In that case fall back to a presence check — the file's
    # existence at the digest-keyed path is the cache-hit signal; the
    # write path only renames into place after sha256 verification, so
    # any file at this path has been verified.
    def cached_complete?(path, expected_size, _expected_digest)
      return false unless File.exist?(path)
      return true if expected_size < 0
      File.size(path) == expected_size
    end

    def cache_path_for(digest)
      safe = normalize_digest(digest).sub(/^sha256:/, "")
      raise ArgumentError, "invalid digest #{digest.inspect}" unless safe.match?(/\A[a-f0-9]{64}\z/i)
      File.join(CACHE_ROOT, "#{safe}.cfs")
    end

    # Coerces any of (sha256:<hex>, <hex>) into the canonical sha256:<hex>
    # form. Lowercases the hex per OCI spec; raises if the input isn't a
    # 64-char hex string (with or without the sha256: prefix).
    def normalize_digest(digest)
      raw = digest.to_s.sub(/^sha256:/, "").downcase
      raise ArgumentError, "invalid digest #{digest.inspect}" unless raw.match?(/\A[a-f0-9]{64}\z/)
      "sha256:#{raw}"
    end

    # Flock-based per-digest lock. Lock file lives next to the cache
    # entry (suffixed .lock) so collision is impossible across digests.
    def with_cache_lock(digest)
      FileUtils.mkdir_p(CACHE_ROOT)
      lock_path = File.join(CACHE_ROOT, "#{digest.sub(/^sha256:/, "")}.lock")
      File.open(lock_path, File::RDWR | File::CREAT, 0o644) do |lock_file|
        lock_file.flock(File::LOCK_EX)
        yield
      end
    end

    def registry_uri(path)
      URI.parse("https://#{registry_host}#{path}")
    end

    def registry_host
      host = @oci_ref.to_s.split("/").first
      raise PullError, "oci_ref #{@oci_ref.inspect} missing registry host" if host.blank?
      host
    end

    # oci_ref shape: "git.ipnode.org/powernode/<name>:<tag>" or
    # "git.ipnode.org/powernode/<name>@sha256:<digest>". Strip the host
    # and the tag/digest suffix to get the repo path used in
    # /v2/<repo_path>/manifests/... URLs.
    def repo_path
      ref = @oci_ref.to_s.sub(%r{\A[^/]+/}, "")
      if ref.include?("@")
        ref.split("@", 2).first
      else
        ref.sub(/:[^:]+\z/, "")
      end
    end

    # The reference is the tag (after final `:`) OR digest (after `@`).
    def reference
      ref = @oci_ref.to_s
      if ref.include?("@")
        ref.split("@", 2).last
      else
        ref.split(":").last
      end
    end

    def basic_auth!
      cred = active_credential!
      username = resolve_registry_username!(cred)
      "Basic " + Base64.strict_encode64("#{username}:#{cred.access_token}")
    end

    def active_credential!
      @credential ||= ::Devops::GitProviderCredential.active.first
      raise AuthError, "no active Devops::GitProviderCredential" unless @credential
      raise AuthError, "credential #{@credential.id} has empty access_token" if @credential.access_token.blank?
      @credential
    end

    # Comprehensive username resolution:
    #   1. operator override via POWERNODE_REGISTRY_USERNAME env (escape hatch)
    #   2. credential.external_username (cached from prior discovery)
    #   3. live discovery via Gitea's /api/v1/user (persisted back for reuse)
    #
    # Persistence step #3 means the next request finds the username at
    # step 2 with no extra round-trip.
    def resolve_registry_username!(cred)
      override = ENV["POWERNODE_REGISTRY_USERNAME"].presence
      return override if override

      cached = cred.external_username.presence
      return cached if cached

      discovered = discover_gitea_username!(cred)
      cred.update_columns(external_username: discovered, updated_at: Time.current)
      discovered
    end

    def discover_gitea_username!(cred)
      base = gitea_api_base(cred)
      uri = URI.parse("#{base}/user")
      resp = http_get(uri, headers: { "Authorization" => "token #{cred.access_token}",
                                       "Accept" => "application/json" })
      unless resp.is_a?(Net::HTTPSuccess)
        raise AuthError,
              "Gitea /api/v1/user lookup failed (HTTP #{resp.code}); " \
              "set POWERNODE_REGISTRY_USERNAME or credential.external_username manually"
      end
      data = JSON.parse(resp.body)
      username = data["login"].to_s
      raise AuthError, "Gitea /api/v1/user returned no login field" if username.blank?
      username
    end

    # Resolves the Gitea API base from the credential's provider. Falls
    # back to a host derived from the artifact's oci_ref so the lookup
    # works even when the provider record has neither api_base_url nor
    # web_base_url populated. GitProvider schema uses these two URL
    # columns (no plain `base_url`).
    def gitea_api_base(cred)
      provider = cred.provider
      api = provider&.api_base_url.presence
      return api.chomp("/") if api
      web = provider&.web_base_url.presence
      return "#{web.chomp('/')}/api/v1" if web

      "https://#{registry_host}/api/v1"
    end

    def emit_event(severity:, kind:, payload:)
      return unless defined?(::System::Fleet::EventBroadcaster)
      account = @account
      ::System::Fleet::EventBroadcaster.emit!(
        account: account,
        kind: kind,
        severity: severity,
        source: "oci_blob_proxy_service",
        payload: payload
      )
    rescue StandardError => e
      ::Rails.logger.warn("[OciBlobProxyService] event emit failed: #{e.message}")
    end
  end
end
