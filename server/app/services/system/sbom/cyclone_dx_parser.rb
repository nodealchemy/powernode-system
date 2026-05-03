# frozen_string_literal: true

module System
  module Sbom
    # Parses a CycloneDX SBOM document into the normalized package shape
    # consumed by ModuleArtifact#sbom_packages and ExposureCalculator.
    #
    # Input: CycloneDX JSON (Hash or String). Tested against syft 1.x output
    # (CycloneDX 1.5).
    #
    # Output: Array of Hashes with string keys:
    #   { "name", "version", "ecosystem", "purl", "license" }
    #
    # Ecosystem is derived from the purl scheme (`pkg:deb/...` -> `deb`,
    # `pkg:gem/...` -> `gem`, etc.) per the Package URL spec. When purl is
    # absent, ecosystem is left blank — ExposureCalculator falls back to
    # the CVE entry's own ecosystem hint.
    #
    # Reference: comprehensive stabilization sweep Phase 10.2.
    class CycloneDxParser
      # Hard cap on packages to retain in the materialized cache. SBOMs from
      # heavy distros (Debian base + many libs) can exceed this; we truncate
      # and log so the JSONB column stays bounded.
      MAX_PACKAGES = 5_000

      # Maps purl `pkg:<scheme>` to a stable ecosystem identifier the
      # VersionMatcher understands. Unknown schemes pass through verbatim
      # (preserves data for future ecosystem support without a parser change).
      PURL_SCHEME_ALIASES = {
        "rubygems" => "gem",
        "golang" => "go"
      }.freeze

      Result = Struct.new(:packages, :truncated, :source_format, keyword_init: true) do
        def truncated?
          truncated == true
        end

        def package_count
          packages.length
        end
      end

      def self.parse(input)
        new.parse(input)
      end

      def parse(input)
        doc = coerce_to_hash(input)
        return empty_result unless cyclone_dx?(doc)

        components = Array(doc["components"])
        truncated = components.length > MAX_PACKAGES

        if truncated
          Rails.logger.warn(
            "[CycloneDxParser] truncating SBOM: #{components.length} components > MAX=#{MAX_PACKAGES}"
          )
          components = components.first(MAX_PACKAGES)
        end

        Result.new(
          packages: components.filter_map { |c| component_to_package(c) },
          truncated: truncated,
          source_format: "cyclonedx-#{doc['specVersion'] || 'unknown'}"
        )
      end

      private

      def coerce_to_hash(input)
        return input if input.is_a?(Hash)
        return {} if input.nil? || (input.respond_to?(:empty?) && input.empty?)

        JSON.parse(input.to_s)
      rescue JSON::ParserError => e
        Rails.logger.warn("[CycloneDxParser] invalid JSON: #{e.message}")
        {}
      end

      def cyclone_dx?(doc)
        doc.is_a?(Hash) && doc["bomFormat"].to_s.casecmp("CycloneDX").zero?
      end

      def component_to_package(component)
        return nil unless component.is_a?(Hash)

        name = component["name"].to_s.strip
        return nil if name.empty?

        purl = component["purl"].to_s
        {
          "name" => name,
          "version" => component["version"].to_s,
          "ecosystem" => ecosystem_from_purl(purl),
          "purl" => purl,
          "license" => extract_license(component)
        }
      end

      # purl format: "pkg:<scheme>/<namespace>/<name>@<version>?qualifiers#subpath"
      # Scheme is the ecosystem identifier; we lowercase + alias for stability.
      def ecosystem_from_purl(purl)
        return "" if purl.empty?
        return "" unless purl.start_with?("pkg:")

        scheme = purl.delete_prefix("pkg:").split("/", 2).first.to_s.downcase
        PURL_SCHEME_ALIASES.fetch(scheme, scheme)
      end

      # CycloneDX licenses can be:
      #   "licenses": [{ "license": { "id": "Apache-2.0" } }]
      #   "licenses": [{ "license": { "name": "Some License" } }]
      #   "licenses": [{ "expression": "Apache-2.0 OR MIT" }]
      # We pick the first usable identifier and stringify; absence -> "".
      def extract_license(component)
        licenses = Array(component["licenses"])
        return "" if licenses.empty?

        first = licenses.first
        return "" unless first.is_a?(Hash)

        license = first["license"]
        if license.is_a?(Hash)
          (license["id"] || license["name"]).to_s
        else
          first["expression"].to_s
        end
      end

      def empty_result
        Result.new(packages: [], truncated: false, source_format: "unknown")
      end
    end
  end
end
