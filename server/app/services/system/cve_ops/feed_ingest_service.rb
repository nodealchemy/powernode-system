# frozen_string_literal: true

require "json"
require "open-uri"

module System
  module CveOps
    # Ingests CVE feed entries from NVD JSON or GitHub Advisory Database
    # into System::Cve rows. Idempotent — re-running with the same feed
    # data updates existing rows rather than creating duplicates.
    #
    # Adapter pattern (consistent with the rest of the System extension):
    #   POWERNODE_CVE_FEED_MODE=real     → fetches from NVD/GHSA
    #   POWERNODE_CVE_FEED_MODE=fixture  → reads from a local JSON fixture
    #   POWERNODE_CVE_FEED_MODE=disabled → no-op
    #
    # Reference: Golden Eclipse plan M-D2-2.
    class FeedIngestService
      Result = Struct.new(:ok?, :ingested_count, :updated_count, :error, keyword_init: true)

      DEFAULT_NVD_URL = "https://services.nvd.nist.gov/rest/json/cves/2.0"

      # NVD v2 API allows up to 2000 results/page. Larger pages mean fewer
      # requests and less rate-limit pressure (anon clients get 5 req/30s).
      NVD_PAGE_SIZE = (ENV["POWERNODE_NVD_PAGE_SIZE"] || 2000).to_i
      # Safety cap so a wide lastModStartDate window (or a full backfill) can't
      # loop unbounded. 25 * 2000 = up to 50k CVEs per run.
      NVD_MAX_PAGES = (ENV["POWERNODE_NVD_MAX_PAGES"] || 25).to_i

      def self.ingest!(source: "nvd", since: nil, fixture_path: nil)
        new.ingest!(source: source, since: since, fixture_path: fixture_path)
      end

      def ingest!(source:, since:, fixture_path:)
        entries =
          case mode
          when "real"     then fetch_from_feed(source, since)
          when "fixture"  then read_fixture(fixture_path)
          when "disabled" then []
          end

        ingested = 0
        updated = 0
        Array(entries).each do |entry|
          row = ::System::Cve.find_or_initialize_by(cve_id: entry["cve_id"])
          row.assign_attributes(
            severity: entry["severity"] || "unknown",
            summary: entry["summary"],
            affected_packages: entry["affected_packages"] || [],
            reference_url: entry["reference_url"],
            published_at: entry["published_at"],
            feed_source: source,
            ingested_at: Time.current
          )
          if row.new_record?
            row.save!
            ingested += 1
          elsif row.changed?
            row.save!
            updated += 1
          end
        end

        Result.new(ok?: true, ingested_count: ingested, updated_count: updated)
      rescue StandardError => e
        Rails.logger.error("[CveFeedIngestService] #{e.class}: #{e.message}")
        Result.new(ok?: false, error: e.message, ingested_count: 0, updated_count: 0)
      end

      private

      def mode
        ENV.fetch("POWERNODE_CVE_FEED_MODE", Rails.env.production? ? "real" : "disabled")
      end

      def fetch_from_feed(source, since)
        raise ArgumentError, "Unsupported source: #{source}" unless source == "nvd"

        start_index = 0
        collected   = []
        pages       = 0

        loop do
          params = { resultsPerPage: NVD_PAGE_SIZE, startIndex: start_index }
          params[:lastModStartDate] = since.iso8601 if since

          json = fetch_nvd_page(params)
          break if json.nil? # page fetch failed — keep the pages we already have

          collected.concat(normalize_nvd(json))
          pages += 1

          total     = json["totalResults"].to_i
          page_size = json["resultsPerPage"].to_i
          start_index += page_size.positive? ? page_size : NVD_PAGE_SIZE

          break if total.zero? || start_index >= total

          if pages >= NVD_MAX_PAGES
            Rails.logger.warn("[CveFeedIngestService] hit NVD_MAX_PAGES=#{NVD_MAX_PAGES} of #{total} total results — truncating this run")
            break
          end

          sleep(nvd_page_delay) # NVD rate-limit politeness between pages
        end

        collected
      end

      # Fetch one NVD page. Extracted so the pagination loop is unit-testable
      # without HTTP (stub this). Returns the parsed JSON Hash, or nil on HTTP
      # error so the caller stops paginating but keeps the pages already pulled.
      def fetch_nvd_page(params)
        open_args = { read_timeout: 30 }
        api_key = ENV["POWERNODE_NVD_API_KEY"]
        open_args["apiKey"] = api_key if api_key.present? # string key => request header

        URI.open("#{DEFAULT_NVD_URL}?#{params.to_query}", open_args) { |io| JSON.parse(io.read) }
      rescue OpenURI::HTTPError => e
        Rails.logger.warn("[CveFeedIngestService] NVD fetch failed (startIndex=#{params[:startIndex]}): #{e.message}")
        nil
      end

      def nvd_page_delay
        (ENV["POWERNODE_NVD_PAGE_DELAY_SECONDS"] || 0.6).to_f
      end

      def normalize_nvd(json)
        Array(json["vulnerabilities"]).map do |entry|
          cve = entry["cve"] || {}
          metrics = (cve.dig("metrics", "cvssMetricV31") || cve.dig("metrics", "cvssMetricV30")).to_a.first
          severity = metrics&.dig("cvssData", "baseSeverity")&.downcase || "unknown"

          {
            "cve_id" => cve["id"],
            "severity" => severity,
            "summary" => cve.dig("descriptions", 0, "value"),
            "reference_url" => cve.dig("references", 0, "url"),
            "published_at" => cve["published"],
            "affected_packages" => extract_affected_packages(cve)
          }
        end.compact
      end

      def extract_affected_packages(cve)
        Array(cve["configurations"]).flat_map do |config|
          Array(config["nodes"]).flat_map do |node|
            Array(node["cpeMatch"]).map do |match|
              cpe = match["criteria"].to_s
              # cpe:2.3:a:vendor:product:version:...
              parts = cpe.split(":")
              {
                "name" => parts[4],
                "version" => parts[5],
                "cpe" => cpe
              }
            end
          end
        end
      end

      def read_fixture(path)
        return [] unless path && File.exist?(path)
        JSON.parse(File.read(path))
      end
    end
  end
end
