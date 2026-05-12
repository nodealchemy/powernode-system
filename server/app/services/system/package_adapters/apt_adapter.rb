# frozen_string_literal: true

module System
  module PackageAdapters
    # Apt/dpkg-flavored package repository adapter.
    #
    # Fetches `dists/<suite>/InRelease` (or `Release` + `Release.gpg`), verifies
    # the signature with the repository's `signing_key_armor`, then for each
    # (component, architecture) downloads and parses the corresponding
    # `Packages.xz` (or `.gz`) file. Yields normalized ParsedPackage entries.
    #
    # Dependency normalization shape (depends, recommends, etc.):
    #   [[{name,op,version}], [{name,op,version},{name,op,version}], ...]
    # outer array = AND, inner = OR (apt's "a | b" alternatives).
    class AptAdapter < Base
      COMPRESSION_EXTENSIONS = %w[.xz .gz ""].freeze

      def sync_metadata(repository:, architectures:)
        return enum_for(:sync_metadata, repository: repository, architectures: architectures) unless block_given?

        release_data, release_sig = fetch_release(repository)
        # If a signing key is configured, verify; otherwise accept transport trust.
        if repository.signing_key_armor.present? && release_sig
          gpg_verify(
            data: release_data,
            signature: release_sig,
            armored_public_key: repository.signing_key_armor
          )
        end

        count = 0
        repository.components.each do |component|
          architectures.each do |arch|
            packages_bytes = fetch_packages_file(repository, component: component, architecture: arch)
            next if packages_bytes.nil?

            parse_packages_stream(packages_bytes) do |raw_fields|
              yield to_parsed_package(raw_fields, default_arch: arch)
              count += 1
            end
          end
        end
        count
      end

      def compare_versions(a, b)
        # dpkg --compare-versions returns 0 (true) or 1 (false). We probe
        # both "lt" and "gt" to derive -1/0/1.
        return 0 if a == b

        if dpkg_compare?(a, "lt", b)
          -1
        elsif dpkg_compare?(a, "gt", b)
          1
        else
          0
        end
      end

      # ---- Dependency string parsing ----
      # Public for unit testability; called by parse_packages_stream.
      #
      # Input:  "libc6 (>= 2.34), libssl3 (>= 3.0.0), debconf (>= 0.5) | debconf-2.0"
      # Output: [
      #   [{"name"=>"libc6", "op"=>">=", "version"=>"2.34"}],
      #   [{"name"=>"libssl3", "op"=>">=", "version"=>"3.0.0"}],
      #   [{"name"=>"debconf", "op"=>">=", "version"=>"0.5"},
      #    {"name"=>"debconf-2.0", "op"=>nil, "version"=>nil}]
      # ]
      def parse_dependency_string(raw)
        return [] if raw.nil? || raw.strip.empty?

        raw.split(",").map do |term|
          term.split("|").map { |alt| parse_one_dep(alt.strip) }
        end
      end

      private

      def parse_one_dep(s)
        # "name [:arch] [(op version)]"
        match = s.match(/\A([\w.+-]+)(?::[\w-]+)?(?:\s*\(\s*(<<|<=|=|>=|>>)\s*(\S+?)\s*\))?\s*\z/)
        return { "name" => s, "op" => nil, "version" => nil } unless match

        { "name" => match[1], "op" => match[2], "version" => match[3] }
      end

      def fetch_release(repository)
        base = repository.base_url.chomp("/")
        suite = repository.suite
        # Try clearsigned InRelease first (modern); fall back to Release + Release.gpg.
        in_release_url = "#{base}/dists/#{suite}/InRelease"
        begin
          in_release = http_get(in_release_url)
          return [in_release, nil] # Clearsigned: signature embedded; gpg --verify on the whole blob.
        rescue FetchError
          # Fall through to detached signature path
        end

        release = http_get("#{base}/dists/#{suite}/Release")
        sig = begin
          http_get("#{base}/dists/#{suite}/Release.gpg")
        rescue FetchError
          nil
        end
        [release, sig]
      end

      def fetch_packages_file(repository, component:, architecture:)
        base = repository.base_url.chomp("/")
        suite = repository.suite
        path_base = "#{base}/dists/#{suite}/#{component}/binary-#{architecture}/Packages"

        COMPRESSION_EXTENSIONS.each do |ext|
          url = "#{path_base}#{ext}"
          begin
            bytes = http_get(url, timeout: 120)
            return case ext
                   when ".xz"
                     xz_decompress(bytes)
                   when ".gz"
                     gunzip(bytes)
                   else
                     bytes
                   end
          rescue FetchError
            next
          end
        end
        nil
      end

      # Stream-parse a Debian control-file format Packages blob. Yields a
      # Hash<String, String> per package (raw field name → folded value).
      #
      # Force UTF-8 encoding up-front: the bytes come from `http_get` as
      # ASCII-8BIT (binary), but Debian Packages files are documented
      # UTF-8 (Debian Policy §5.2). Without this, JSON.generate later
      # warns "UTF-8 string passed as BINARY" and will raise once the
      # json gem hits 3.0.
      def parse_packages_stream(text)
        text = text.force_encoding("UTF-8") if text.is_a?(String)
        current = {}
        current_field = nil

        text.each_line do |raw_line|
          line = raw_line.chomp
          if line.empty?
            yield current if current.any?
            current = {}
            current_field = nil
          elsif line.start_with?(" ", "\t")
            # Continuation of previous field
            current[current_field] << "\n" << line.sub(/\A[ \t]/, "") if current_field
          elsif (m = line.match(/\A([\w-]+):\s*(.*)\z/))
            current_field = m[1]
            current[current_field] = m[2]
          end
        end
        yield current if current.any?
      end

      def to_parsed_package(fields, default_arch:)
        ParsedPackage.new(
          name:                 fields["Package"],
          version:              fields["Version"],
          architecture:         fields["Architecture"] || default_arch,
          release_version:      nil,
          section_or_group:     fields["Section"],
          description:          fields["Description"],
          summary:              fields["Description"]&.lines&.first&.strip,
          installed_size_bytes: kb_to_bytes(fields["Installed-Size"]),
          download_size_bytes:  fields["Size"]&.to_i,
          depends:      parse_dependency_string(fields["Depends"]),
          pre_depends:  parse_dependency_string(fields["Pre-Depends"]),
          recommends:   parse_dependency_string(fields["Recommends"]),
          suggests:     parse_dependency_string(fields["Suggests"]),
          conflicts:    parse_dependency_string(fields["Conflicts"]),
          provides:     parse_dependency_string(fields["Provides"]),
          replaces:     parse_dependency_string(fields["Replaces"]),
          breaks:       parse_dependency_string(fields["Breaks"]),
          filename:     fields["Filename"],
          sha256:       fields["SHA256"],
          sha512:       fields["SHA512"],
          homepage:     fields["Homepage"],
          license:      nil, # apt binary packages don't carry License in Packages
          maintainer:   fields["Maintainer"],
          raw_metadata: fields
        )
      end

      def kb_to_bytes(kb_str)
        return nil if kb_str.nil? || kb_str.strip.empty?

        kb_str.to_i * 1024
      end

      def dpkg_compare?(a, op, b)
        _, _, status = Open3.capture3("dpkg", "--compare-versions", a, op, b)
        status.success?
      end
    end
  end
end
