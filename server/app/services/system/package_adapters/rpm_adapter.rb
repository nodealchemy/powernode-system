# frozen_string_literal: true

require "nokogiri"

module System
  module PackageAdapters
    # RPM/dnf-flavored package repository adapter.
    #
    # Fetches `repodata/repomd.xml` (optionally verifying with a detached
    # `.asc` if `rpm_config.gpgcheck` is true and `signing_key_armor` is set),
    # locates the `primary` data type entry, downloads + gunzips the
    # `primary.xml.gz`, then SAX-parses to yield ParsedPackage entries.
    #
    # Unlike apt's multi-arch single-chroot model, rpm REQUIRES one job per
    # arch — `dnf --installroot --forcearch` is incomplete and unsafe. The CI
    # workflow's strategy matrix collapses to one job per arch for rpm
    # repositories.
    class RpmAdapter < Base
      NAMESPACES = {
        "common" => "http://linux.duke.edu/metadata/common",
        "rpm"    => "http://linux.duke.edu/metadata/rpm"
      }.freeze

      def sync_metadata(repository:, architectures:)
        return enum_for(:sync_metadata, repository: repository, architectures: architectures) unless block_given?

        repomd_bytes = fetch_repomd(repository)
        if repository.gpgcheck? && repository.signing_key_armor.present?
          sig = fetch_repomd_signature(repository)
          gpg_verify(
            data: repomd_bytes,
            signature: sig,
            armored_public_key: repository.signing_key_armor
          ) if sig
        end

        primary_relpath = locate_primary_xml(repomd_bytes)
        raise ParseError, "primary.xml not found in repomd" if primary_relpath.nil?

        primary_bytes = http_get(URI.join("#{repository.base_url.chomp('/')}/", primary_relpath).to_s, timeout: 180)
        primary_xml = primary_relpath.end_with?(".gz") ? gunzip(primary_bytes) : primary_bytes

        count = 0
        parse_primary_xml(primary_xml).each do |fields|
          next unless architectures.include?(fields[:arch]) || architectures.include?("noarch") && fields[:arch] == "noarch"

          yield to_parsed_package(fields)
          count += 1
        end
        count
      end

      # rpmvercmp algorithm (pure Ruby). The canonical implementation lives
      # in librpmio; this port handles the common cases: alphanumeric
      # tokenization, tilde-as-less-than, caret-as-pre-release. Matches dnf's
      # behavior for the version strings we actually encounter in package
      # indexes.
      def compare_versions(a, b)
        return 0 if a == b

        a_epoch, a_ver, a_rel = split_evr(a)
        b_epoch, b_ver, b_rel = split_evr(b)

        cmp = a_epoch.to_i <=> b_epoch.to_i
        return cmp unless cmp.zero?

        cmp = rpmvercmp(a_ver, b_ver)
        return cmp unless cmp.zero?

        rpmvercmp(a_rel.to_s, b_rel.to_s)
      end

      private

      def fetch_repomd(repository)
        url = "#{repository.base_url.chomp('/')}/repodata/repomd.xml"
        http_get(url)
      end

      def fetch_repomd_signature(repository)
        url = "#{repository.base_url.chomp('/')}/repodata/repomd.xml.asc"
        http_get(url)
      rescue FetchError
        nil
      end

      def locate_primary_xml(repomd_bytes)
        doc = Nokogiri::XML(repomd_bytes)
        ns = { "r" => "http://linux.duke.edu/metadata/repo" }
        node = doc.at_xpath("/r:repomd/r:data[@type='primary']/r:location", ns)
        node&.[]("href")
      end

      def parse_primary_xml(xml_bytes)
        doc = Nokogiri::XML(xml_bytes)
        packages = []
        doc.xpath("//common:package[@type='rpm']", NAMESPACES).each do |pkg|
          packages << parse_package_node(pkg)
        end
        packages
      end

      def parse_package_node(pkg)
        version_node = pkg.at_xpath("common:version", NAMESPACES)
        location_node = pkg.at_xpath("common:location", NAMESPACES)
        format_node = pkg.at_xpath("common:format", NAMESPACES)
        checksum_node = pkg.at_xpath("common:checksum[@type='sha256']", NAMESPACES) ||
                        pkg.at_xpath("common:checksum", NAMESPACES)
        size_node = pkg.at_xpath("common:size", NAMESPACES)

        {
          name:        pkg.at_xpath("common:name", NAMESPACES)&.text,
          arch:        pkg.at_xpath("common:arch", NAMESPACES)&.text,
          epoch:       version_node&.[]("epoch"),
          version:     version_node&.[]("ver"),
          release:     version_node&.[]("rel"),
          summary:     pkg.at_xpath("common:summary", NAMESPACES)&.text,
          description: pkg.at_xpath("common:description", NAMESPACES)&.text,
          url:         pkg.at_xpath("common:url", NAMESPACES)&.text,
          filename:    location_node&.[]("href"),
          sha256:      checksum_node&.text,
          installed_size_bytes: size_node&.[]("installed")&.to_i,
          download_size_bytes:  size_node&.[]("package")&.to_i,
          license:     format_node&.at_xpath("rpm:license", NAMESPACES)&.text,
          group:       format_node&.at_xpath("rpm:group", NAMESPACES)&.text,
          packager:    format_node&.at_xpath("rpm:packager", NAMESPACES)&.text,
          requires:    extract_entries(format_node, "rpm:requires"),
          recommends:  extract_entries(format_node, "rpm:recommends"),
          suggests:    extract_entries(format_node, "rpm:suggests"),
          conflicts:   extract_entries(format_node, "rpm:conflicts"),
          provides:    extract_entries(format_node, "rpm:provides"),
          obsoletes:   extract_entries(format_node, "rpm:obsoletes")
        }
      end

      def extract_entries(format_node, xpath)
        return [] unless format_node

        list_node = format_node.at_xpath(xpath, NAMESPACES)
        return [] unless list_node

        list_node.xpath("rpm:entry", NAMESPACES).map do |entry|
          op = case entry["flags"]
               when "LT" then "<<"
               when "LE" then "<="
               when "EQ" then "="
               when "GE" then ">="
               when "GT" then ">>"
               else nil
               end
          # rpm dep groups don't have apt's `|` alternatives within a single
          # entry, so we wrap each in a single-element OR group to match the
          # normalized shape.
          [{ "name" => entry["name"], "op" => op, "version" => entry["ver"] }]
        end
      end

      def to_parsed_package(f)
        ParsedPackage.new(
          name:                 f[:name],
          version:              f[:version],
          architecture:         f[:arch],
          release_version:      f[:release],
          section_or_group:     f[:group],
          description:          f[:description],
          summary:              f[:summary],
          installed_size_bytes: f[:installed_size_bytes],
          download_size_bytes:  f[:download_size_bytes],
          depends:      f[:requires],
          pre_depends:  [],
          recommends:   f[:recommends],
          suggests:     f[:suggests],
          conflicts:    f[:conflicts],
          provides:     f[:provides],
          replaces:     f[:obsoletes],
          breaks:       [],
          filename:     f[:filename],
          sha256:       f[:sha256],
          sha512:       nil,
          homepage:     f[:url],
          license:      f[:license],
          maintainer:   f[:packager],
          raw_metadata: f.transform_keys(&:to_s)
        )
      end

      def split_evr(evr)
        # Format: [epoch:]version[-release]
        epoch = "0"
        rest = evr
        if (m = rest.match(/\A(\d+):(.*)\z/))
          epoch = m[1]
          rest = m[2]
        end
        if (m = rest.match(/\A(.*?)-([^-]+)\z/))
          [epoch, m[1], m[2]]
        else
          [epoch, rest, ""]
        end
      end

      # Port of librpmio rpmvercmp. Tokenizes each version into alternating
      # runs of digits and letters, separated by ".", "-", etc. Compares
      # segment-by-segment; tilde sorts before empty (1.0~rc1 < 1.0); caret
      # sorts after empty (1.0 < 1.0^snapshot). Numeric segments beat alpha
      # segments when one side is empty. Leading zeros in numeric segments
      # are stripped, then the longer-digit-string wins.
      #
      # Reference: librpmio/rpmvercmp.c in upstream rpm.
      def rpmvercmp(a, b)
        return 0 if a == b

        a = a.to_s
        b = b.to_s
        ai = bi = 0

        while ai < a.length || bi < b.length
          # Skip non-alnum, non-tilde, non-caret separators on both sides
          while ai < a.length && !ralnum?(a[ai]) && a[ai] != "~" && a[ai] != "^"
            ai += 1
          end
          while bi < b.length && !ralnum?(b[bi]) && b[bi] != "~" && b[bi] != "^"
            bi += 1
          end

          # Tilde sorts before anything else (including empty/eof)
          a_ch = ai < a.length ? a[ai] : nil
          b_ch = bi < b.length ? b[bi] : nil
          if a_ch == "~" || b_ch == "~"
            return 1  if a_ch != "~"
            return -1 if b_ch != "~"
            ai += 1; bi += 1
            next
          end

          # Caret sorts after empty but before alnum. So:
          #   * If a has ^ and b is exhausted → a > b (return 1)
          #   * If b has ^ and a is exhausted → a < b (return -1)
          #   * Otherwise consume both carets and continue
          if a_ch == "^" || b_ch == "^"
            return -1 if a_ch.nil?      # a empty, b has ^ → a < b
            return 1  if b_ch.nil?      # b empty, a has ^ → a > b
            return 1  if a_ch != "^"    # b has ^, a has alnum → a > b
            return -1 if b_ch != "^"    # a has ^, b has alnum → a < b
            ai += 1; bi += 1
            next
          end

          # If EITHER side is now exhausted, the loop is done — the final
          # length-comparison block decides the winner. This mirrors the
          # `if (!(*one && *two)) break;` in librpmio/rpmvercmp.c.
          break if a_ch.nil? || b_ch.nil?

          # Extract a run of digits or alphas from a
          a_start = ai
          a_is_num = !a_ch.nil? && a_ch =~ /\d/
          if a_is_num
            ai += 1 while ai < a.length && a[ai] =~ /\d/
          elsif !a_ch.nil?
            ai += 1 while ai < a.length && a[ai] =~ /[a-zA-Z]/
          end
          a_seg = a[a_start...ai]

          # Extract the matching segment type from b
          b_start = bi
          if a_is_num
            bi += 1 while bi < b.length && b[bi] =~ /\d/
          else
            bi += 1 while bi < b.length && b[bi] =~ /[a-zA-Z]/
          end
          b_seg = b[b_start...bi]

          # One side empty: numeric beats alpha; alpha loses to anything
          if a_seg.empty? && !b_seg.empty?
            return a_is_num ? 1 : -1
          end
          if !a_seg.empty? && b_seg.empty?
            return a_is_num ? 1 : -1
          end

          if a_is_num
            a_tok = a_seg.sub(/\A0+/, "")
            b_tok = b_seg.sub(/\A0+/, "")
            return 1  if a_tok.length > b_tok.length
            return -1 if a_tok.length < b_tok.length
            cmp = a_tok <=> b_tok
            return cmp unless cmp.zero?
          else
            cmp = a_seg <=> b_seg
            return cmp unless cmp.zero?
          end
        end

        # Strings reached the end at the same time → equal
        return 0 if ai >= a.length && bi >= b.length

        ai >= a.length ? -1 : 1
      end

      def ralnum?(ch)
        return false if ch.nil?

        ch =~ /[a-zA-Z0-9]/
      end
    end
  end
end
