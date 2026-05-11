# frozen_string_literal: true

module System
  module PackageAdapters
    # Abstract base class for apt/rpm package-repository adapters.
    #
    # Concrete subclasses implement upstream-fetch + format-parse; the
    # ParsedPackage struct is the normalized shape that PackageRepositorySyncService
    # upserts into system_packages rows.
    class Base
      class FetchError < StandardError; end
      class ParseError < StandardError; end
      class SignatureError < StandardError; end

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
      def http_get(url, timeout: 60)
        conn = Faraday.new do |f|
          f.options.timeout = timeout
          f.options.open_timeout = 15
          f.adapter Faraday.default_adapter
        end
        response = conn.get(url)
        unless response.status.between?(200, 299)
          raise FetchError, "HTTP #{response.status} fetching #{url}"
        end

        response.body
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
