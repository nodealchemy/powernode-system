# frozen_string_literal: true

module System
  module PackageAdapters
    # Abstract base class for apt/rpm package-repository adapters.
    #
    # Concrete subclasses implement upstream-fetch + format-parse; the
    # ParsedPackage struct is the normalized shape that PackageRepositorySyncService
    # upserts into system_packages rows.
    class Base
      # Raised for any upstream-index fetch failure. `status` is the HTTP
      # response code when the failure WAS an HTTP response (e.g. 404, 503),
      # and nil for a transport-level failure (timeout, connection reset, TLS).
      # This lets callers distinguish a definitively-absent resource
      # (404/410 — tolerate) from a transient/transport failure (retry, and
      # never treat as "removed upstream").
      class FetchError < StandardError
        attr_reader :status

        def initialize(message = nil, status: nil)
          super(message)
          @status = status
        end

        # A definitively-absent resource. Distinct from a transport failure,
        # where the resource may well exist but couldn't be retrieved.
        def not_found?
          status == 404 || status == 410
        end
      end

      class ParseError < StandardError; end
      class SignatureError < StandardError; end

      # Retry budget + backoff for TRANSIENT fetch failures (network errors,
      # 5xx, 429). Definitive 4xx (e.g. 404) are never retried. Constants to
      # match the adapters' other tuned fetch parameters (timeouts, compression
      # extension list).
      MAX_FETCH_ATTEMPTS = 3
      RETRY_BACKOFF_SECONDS = 0.5

      # Normalized package representation yielded by #sync_metadata. Mirrors
      # the system_packages column shape so PackageRepositorySyncService can
      # batch-upsert with minimal munging.
      ParsedPackage = Struct.new(
        :name, :version, :architecture, :release_version, :section_or_group,
        :description, :summary, :installed_size_bytes, :download_size_bytes,
        :depends, :pre_depends, :recommends, :suggests, :conflicts,
        :provides, :replaces, :breaks,
        :filename, :sha256, :sha512, :homepage, :license, :maintainer,
        :raw_metadata,
        keyword_init: true
      )

      # Fetch + parse the upstream index for one repository.
      #
      # @param repository [System::PackageRepository]
      # @param architectures [Array<String>] e.g. ["amd64", "arm64"]
      # @yield [ParsedPackage] one per package found upstream
      # @return [Integer] total packages yielded
      def sync_metadata(repository:, architectures:, &block)
        raise NotImplementedError
      end

      # Returns a STABLE digest of the upstream index metadata that changes iff
      # the package set/metadata changed — cheap to fetch (one small index
      # file, not the full Packages/primary). The sync fast-path compares it to
      # the last stored value and skips fetch+parse+diff entirely when
      # unchanged. Returns nil when the adapter can't cheaply/robustly compute
      # one (the caller then always performs a full sync). MUST be stable
      # across upstream re-signs (ignore signatures/timestamps).
      def fingerprint(repository:)
        nil
      end

      # Compare two version strings. Returns -1, 0, or 1 (suitable for sort).
      # Adapter-specific because dpkg and rpm version semantics differ
      # (epochs, debian revisions, rpm release qualifiers, etc.).
      #
      # @param a [String]
      # @param b [String]
      # @return [Integer]
      def compare_versions(a, b)
        raise NotImplementedError
      end

      protected

      # Shared HTTP fetch helper. Returns the response body (binary).
      # Subclasses use this for index downloads. Configurable timeout to
      # accommodate slow mirrors; default 60s.
      #
      # ALL failures surface as FetchError (with `status` set to the HTTP code,
      # or nil for a transport-level failure), so callers have a single
      # exception type AND can tell a definitively-absent resource (404) from a
      # transient failure worth retrying / never treating as "removed upstream".
      # Transient failures (network error, 5xx, 429) are retried with backoff;
      # a definitive 4xx is raised immediately.
      def http_get(url, timeout: 60)
        attempt = 0
        loop do
          attempt += 1
          error =
            begin
              conn = Faraday.new do |f|
                f.options.timeout = timeout
                f.options.open_timeout = 15
                f.adapter Faraday.default_adapter
              end
              response = conn.get(url)
              return response.body if response.status.between?(200, 299)

              FetchError.new("HTTP #{response.status} fetching #{url}", status: response.status)
            rescue Faraday::Error => e
              # Transport-level failure (timeout, connection reset, TLS) — no
              # HTTP status. Funnel to FetchError with a nil status.
              FetchError.new("transport error fetching #{url}: #{e.class}", status: nil)
            end

          raise error unless retryable_fetch_status?(error.status)
          raise error if attempt >= MAX_FETCH_ATTEMPTS

          sleep(RETRY_BACKOFF_SECONDS * attempt)
        end
      end

      # Worth retrying: a network error (nil status), any 5xx, or 429. A
      # definitive 4xx (404/403/…) will never succeed on retry.
      def retryable_fetch_status?(status)
        status.nil? || status >= 500 || status == 429
      end

      # GPG verify a detached signature against the given armored public key.
      # Returns true on success; raises SignatureError on failure.
      # Uses a per-call tmpdir as GNUPGHOME so we don't pollute the host
      # keyring or have inter-call interference.
      def gpg_verify(data:, signature:, armored_public_key:)
        require "tempfile"
        require "fileutils"
        require "open3"

        Dir.mktmpdir do |tmphome|
          File.chmod(0o700, tmphome)
          key_path = File.join(tmphome, "pubkey.asc")
          File.write(key_path, armored_public_key)

          _, _, status = Open3.capture3(
            { "GNUPGHOME" => tmphome },
            "gpg", "--batch", "--quiet", "--import", key_path
          )
          unless status.success?
            raise SignatureError, "Failed to import signing key"
          end

          Tempfile.create("apt-data") do |data_file|
            data_file.binmode
            data_file.write(data)
            data_file.flush

            Tempfile.create("apt-sig") do |sig_file|
              sig_file.binmode
              sig_file.write(signature)
              sig_file.flush

              _, stderr, status = Open3.capture3(
                { "GNUPGHOME" => tmphome },
                "gpg", "--batch", "--quiet", "--verify", sig_file.path, data_file.path
              )
              unless status.success?
                raise SignatureError, "Signature verification failed: #{stderr.strip}"
              end
            end
          end
        end
        true
      end

      # Decompress gzip-compressed bytes. Used for Packages.gz, primary.xml.gz.
      def gunzip(bytes)
        require "zlib"
        Zlib::GzipReader.new(StringIO.new(bytes)).read
      end

      # Decompress xz-compressed bytes by shelling out (no pure-Ruby xz reader
      # in the standard library). Used for Packages.xz which is the default
      # compression in modern apt repos.
      def xz_decompress(bytes)
        require "open3"
        stdout, stderr, status = Open3.capture3("xz", "-dc", stdin_data: bytes, binmode: true)
        unless status.success?
          raise ParseError, "xz decompress failed: #{stderr.strip}"
        end

        stdout
      end
    end
  end
end
