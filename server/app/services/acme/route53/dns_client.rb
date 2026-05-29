# frozen_string_literal: true

require "net/http"
require "uri"
require "nokogiri"
require "aws-sigv4"

module Acme
  module Route53
    # AWS Route53 DNS adapter. Conforms to the Acme::DnsClient contract
    # so the records controller doesn't branch on provider.
    #
    # Route53 is materially different from the token-based providers:
    #
    #   - Auth is AWS SigV4, not a bearer token. We reuse the
    #     `aws-sigv4` gem (already in the bundle via aws-sdk-s3) rather
    #     than pulling in the full aws-sdk-route53 SDK. The signer is
    #     ALWAYS region "us-east-1" — Route53 is a global service whose
    #     endpoint lives in us-east-1 regardless of where the operator's
    #     other resources are. The operator-supplied `region` is stored
    #     for completeness/UX but never used for signing.
    #   - The API speaks XML, not JSON. Requests that mutate records
    #     POST a <ChangeResourceRecordSetsRequest> batch; responses are
    #     parsed with Nokogiri (matching the repo's existing XML usage in
    #     System::PackageAdapters::RpmAdapter).
    #   - Hosted-zone ids come back prefixed ("/hostedzone/Z123"). We
    #     strip the prefix in normalized output so callers see the bare
    #     "Z123", and re-add it on the wire when needed.
    #   - Route53 has NO per-record id. A ResourceRecordSet is keyed by
    #     (name, type). We synthesize a stable record_id of "TYPE:name."
    #     so get/update/delete can round-trip through the same contract
    #     the other adapters use.
    #   - DELETE requires the FULL existing record body (name, type, ttl,
    #     and every value), so delete_record re-fetches the rrset first.
    #   - There is no "proxied" concept — that flag is ignored.
    #
    # Plan reference: E4 (Route53 record management).
    class DnsClient
      BASE_URL = "https://route53.amazonaws.com/2013-04-01"
      SIGNING_REGION = "us-east-1" # Route53 is global; always sign here.
      SERVICE = "route53"
      DEFAULT_TIMEOUT = 10
      ALLOWED_RECORD_TYPES = %w[A AAAA CNAME TXT MX SRV NS CAA PTR].freeze

      Result = ::Acme::Cloudflare::DnsClient::Result

      class ApiError < ::Acme::Cloudflare::DnsClient::ApiError; end

      # Built by Acme::DnsClient.for as `new(api_token:, **opts)`. The
      # token-shaped keyword is meaningless for Route53, so we accept it
      # and discard it; the real credentials arrive as access_key_id /
      # secret_access_key / region. A bare positional credentials Hash is
      # also accepted for direct construction outside the factory.
      #
      # Both shapes flow through `*args` + `**opts`: Ruby 3 routes a
      # brace-less trailing hash (`new("access_key_id" => ...)`) into
      # `**opts` regardless of key type, while an explicit-braces hash
      # (`new({...})`) and the factory's keyword arguments land in `args`
      # and `opts` respectively. Declaring explicit keyword parameters
      # here would make Ruby raise "unknown keyword" on the string-keyed
      # positional form, so we normalize manually instead.
      def initialize(*args, **opts)
        positional = args.first.is_a?(Hash) ? args.first : {}
        creds = positional.merge(opts).transform_keys(&:to_s)

        @access_key_id     = creds["access_key_id"].to_s
        @secret_access_key = creds["secret_access_key"].to_s
        @region            = creds["region"].to_s
        @timeout           = creds.key?("timeout") ? creds["timeout"] : DEFAULT_TIMEOUT
        @logger            = creds["logger"] || ::Rails.logger
        # creds["api_token"] is accepted from the factory and ignored —
        # Route53 authenticates with SigV4, not a bearer token.

        if @access_key_id.strip.empty? || @secret_access_key.strip.empty?
          raise ArgumentError, "access_key_id and secret_access_key are required"
        end

        @signer = ::Aws::Sigv4::Signer.new(
          service: SERVICE,
          region: SIGNING_REGION,
          access_key_id: @access_key_id,
          secret_access_key: @secret_access_key
        )
      end

      # ── Zones ────────────────────────────────────────────────────────

      # GET /hostedzone — Route53 has no server-side name filter, so we
      # client-filter to honour the contract.
      def list_zones(name: nil, per_page: 50, page: 1)
        _ = page # Route53 paginates by marker, not page number; first page only
        result = get("/hostedzone", params: { maxitems: per_page })
        return result unless result.ok?

        zones = result.data.xpath("//HostedZone").map { |z| normalize_zone(z) }
        zones = zones.select { |z| zone_name_matches?(z[:name], name) } if name.present?
        Result.new(ok: true, data: zones, http_status: result.http_status)
      end

      # GET /hostedzone/:id
      def get_zone(zone_id)
        result = get("/hostedzone/#{escape(strip_zone_prefix(zone_id))}")
        return result unless result.ok?

        node = result.data.at_xpath("//HostedZone")
        unless node
          return Result.new(ok: false, error: "Hosted zone #{zone_id} not found in response",
                            http_status: result.http_status)
        end
        Result.new(ok: true, data: normalize_zone(node), http_status: result.http_status)
      end

      # ── Records ──────────────────────────────────────────────────────

      # GET /hostedzone/:zone_id/rrset
      def list_records(zone_id, type: nil, name: nil, per_page: 100, page: 1)
        _ = page
        params = { maxitems: per_page }
        params[:type] = type.to_s.upcase if type.present?
        params[:name] = fqdn(name, zone_id) if name.present?

        result = get("/hostedzone/#{escape(strip_zone_prefix(zone_id))}/rrset", params: params)
        return result unless result.ok?

        recs = result.data.xpath("//ResourceRecordSet").flat_map { |rr| normalize_record(rr, zone_id) }
        recs = recs.select { |r| r[:type] == type.to_s.upcase } if type.present?
        recs = recs.select { |r| zone_name_matches?(r[:name], fqdn(name, zone_id)) } if name.present?
        Result.new(ok: true, data: recs, http_status: result.http_status)
      end

      # Route53 has no GET-single-record endpoint. The synthetic
      # record_id is "TYPE:name."; we list the zone and select the match.
      def get_record(zone_id, record_id)
        rec_type, rec_name = split_record_id(record_id)
        listing = list_records(zone_id, type: rec_type, name: rec_name)
        return listing unless listing.ok?

        match = Array(listing.data).find { |r| r[:id] == record_id.to_s }
        unless match
          return Result.new(ok: false, error: "Record #{record_id.inspect} not found in zone #{zone_id}",
                            http_status: 404)
        end
        Result.new(ok: true, data: match, http_status: listing.http_status)
      end

      # POST /hostedzone/:zone_id/rrset with a single UPSERT change.
      # UPSERT covers both create and update (Route53 has no separate
      # create verb — an UPSERT replaces any existing rrset of the same
      # name+type, which is the closest match to create semantics).
      def create_record(zone_id, type:, name:, content:, ttl: 1, proxied: false, **extras)
        validate_record_type!(type)
        _ = proxied # Route53 has no proxied concept

        rec_type = type.to_s.upcase
        rec_name = fqdn(name, zone_id)
        change_xml = change_batch_xml(
          action: "UPSERT",
          name: rec_name,
          type: rec_type,
          ttl: normalize_ttl(ttl),
          values: [ content.to_s ]
        )

        result = post_change(zone_id, change_xml)
        return result unless result.ok?

        Result.new(
          ok: true,
          data: {
            id: build_record_id(rec_type, rec_name),
            zone_id: strip_zone_prefix(zone_id),
            zone_name: nil,
            type: rec_type,
            name: rec_name,
            content: content.to_s,
            ttl: normalize_ttl(ttl),
            proxied: false,
            change_status: change_status(result.data),
            change_id: change_id(result.data)
          }.compact,
          http_status: result.http_status
        )
      end

      # Route53 update == UPSERT. The synthetic record_id pins the
      # name+type; supplied attrs override content/ttl. We re-fetch the
      # existing rrset to fill any attr the caller omitted.
      def update_record(zone_id, record_id, attrs)
        attrs = (attrs || {}).transform_keys(&:to_sym)
        validate_record_type!(attrs[:type]) if attrs[:type].present?

        existing = get_record(zone_id, record_id)
        return existing unless existing.ok?
        current = existing.data

        rec_type = (attrs[:type].presence || current[:type]).to_s.upcase
        rec_name = attrs[:name].present? ? fqdn(attrs[:name], zone_id) : current[:name]
        rec_ttl  = attrs[:ttl].present? ? normalize_ttl(attrs[:ttl]) : current[:ttl]
        content  = attrs[:content].present? ? attrs[:content].to_s : current[:content]

        change_xml = change_batch_xml(
          action: "UPSERT",
          name: rec_name,
          type: rec_type,
          ttl: rec_ttl,
          values: [ content ]
        )

        result = post_change(zone_id, change_xml)
        return result unless result.ok?

        Result.new(
          ok: true,
          data: {
            id: build_record_id(rec_type, rec_name),
            zone_id: strip_zone_prefix(zone_id),
            type: rec_type,
            name: rec_name,
            content: content,
            ttl: rec_ttl,
            proxied: false,
            change_status: change_status(result.data),
            change_id: change_id(result.data)
          }.compact,
          http_status: result.http_status
        )
      end

      # DELETE requires the exact existing rrset body, so we re-fetch
      # first, then POST a DELETE change. The re-fetch lists the zone's
      # rrsets unfiltered and selects the (type, name) match locally —
      # Route53's DELETE needs every current value of the rrset, so we
      # read the whole set rather than a server-filtered slice.
      def delete_record(zone_id, record_id)
        listing = list_records(zone_id)
        return listing unless listing.ok?

        current = Array(listing.data).find { |r| r[:id] == record_id.to_s }
        unless current
          return Result.new(ok: false,
                            error: "Record #{record_id.inspect} not found in zone #{zone_id}",
                            http_status: 404)
        end

        change_xml = change_batch_xml(
          action: "DELETE",
          name: current[:name],
          type: current[:type],
          ttl: current[:ttl],
          values: Array(current[:values]).presence || [ current[:content] ].compact
        )

        result = post_change(zone_id, change_xml)
        return result unless result.ok?
        Result.new(ok: true,
                    data: { deleted: true, change_status: change_status(result.data),
                            change_id: change_id(result.data) }.compact,
                    http_status: result.http_status)
      end

      private

      # ── HTTP ─────────────────────────────────────────────────────────

      def get(path, params: {})
        uri = URI("#{BASE_URL}#{path}")
        uri.query = URI.encode_www_form(params) if params.any?
        request(:get, uri)
      end

      # POST /hostedzone/:zone_id/rrset with an XML change batch.
      def post_change(zone_id, body_xml)
        uri = URI("#{BASE_URL}/hostedzone/#{escape(strip_zone_prefix(zone_id))}/rrset")
        request(:post, uri, body: body_xml, content_type: "application/xml")
      end

      def request(method, uri, body: nil, content_type: nil)
        signed_headers = sign(method: method, uri: uri, body: body, content_type: content_type)

        req = build_net_request(method, uri, body)
        signed_headers.each { |k, v| req[k] = v }
        req["Accept"] = "application/xml"
        req["Content-Type"] = content_type if content_type

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.read_timeout = @timeout
        http.open_timeout = @timeout

        response = http.request(req)
        parse_response(response)
      rescue Net::OpenTimeout, Net::ReadTimeout => e
        Result.new(ok: false, error: "Route53 API timeout: #{e.message}")
      rescue StandardError => e
        @logger.error("[Acme::Route53::DnsClient] #{e.class}: #{e.message}")
        Result.new(ok: false, error: "Route53 API error: #{e.message}")
      end

      def build_net_request(method, uri, body)
        case method
        when :get
          Net::HTTP::Get.new(uri)
        when :post
          req = Net::HTTP::Post.new(uri)
          req.body = body.to_s
          req
        else
          raise ArgumentError, "Unsupported HTTP method #{method.inspect}"
        end
      end

      # Sign with SigV4 and return the headers AWS wants applied. The
      # signer signs against the FULL url (query included) so the
      # canonical request matches what we actually send.
      def sign(method:, uri:, body:, content_type:)
        headers = {}
        headers["content-type"] = content_type if content_type
        signature = @signer.sign_request(
          http_method: method.to_s.upcase,
          url: uri.to_s,
          headers: headers,
          body: body.to_s
        )
        signature.headers
      end

      # ── Parsing ──────────────────────────────────────────────────────

      # Route53 success → Nokogiri document (namespaces stripped so
      # callers query plain element names). Error → <ErrorResponse> with
      # <Error><Code>/<Message>. We normalize both into the shared Result.
      def parse_response(response)
        body = response.body.to_s
        doc = body.empty? ? Nokogiri::XML("") : Nokogiri::XML(body)
        doc.remove_namespaces!

        if response.is_a?(Net::HTTPSuccess)
          Result.new(ok: true, data: doc, http_status: response.code.to_i)
        else
          error_node = doc.at_xpath("//Error")
          code = error_node&.at_xpath("Code")&.text
          msg = error_node&.at_xpath("Message")&.text ||
                doc.at_xpath("//Message")&.text ||
                "Route53 returned HTTP #{response.code}"
          Result.new(
            ok: false,
            error: msg,
            http_status: response.code.to_i,
            cf_errors: [ { code: code, message: msg } ]
          )
        end
      rescue Nokogiri::XML::SyntaxError => e
        Result.new(
          ok: false,
          error: "Invalid XML from Route53 (HTTP #{response.code}): #{e.message}",
          http_status: response.code.to_i
        )
      end

      # ── XML build ────────────────────────────────────────────────────

      # Build a single-change <ChangeResourceRecordSetsRequest> body.
      # DELETE/UPSERT both share this shape; only <Action> and the value
      # set differ.
      def change_batch_xml(action:, name:, type:, ttl:, values:)
        records_xml = Array(values).map do |v|
          "<ResourceRecord><Value>#{xml_escape(v)}</Value></ResourceRecord>"
        end.join

        <<~XML
          <?xml version="1.0" encoding="UTF-8"?>
          <ChangeResourceRecordSetsRequest xmlns="https://route53.amazonaws.com/doc/2013-04-01/">
            <ChangeBatch>
              <Changes>
                <Change>
                  <Action>#{action}</Action>
                  <ResourceRecordSet>
                    <Name>#{xml_escape(name)}</Name>
                    <Type>#{xml_escape(type)}</Type>
                    <TTL>#{ttl.to_i}</TTL>
                    <ResourceRecords>#{records_xml}</ResourceRecords>
                  </ResourceRecordSet>
                </Change>
              </Changes>
            </ChangeBatch>
          </ChangeResourceRecordSetsRequest>
        XML
      end

      # ── Normalization ────────────────────────────────────────────────

      def normalize_zone(node)
        {
          id: strip_zone_prefix(node.at_xpath("Id")&.text),
          name: node.at_xpath("Name")&.text.to_s,
          status: "active",
          records_count: node.at_xpath("ResourceRecordSetCount")&.text&.to_i,
          private: node.at_xpath("Config/PrivateZone")&.text == "true"
        }.compact
      end

      # A Route53 ResourceRecordSet can carry multiple <ResourceRecord>
      # values (e.g. an A record with several IPs). To keep the contract
      # one-row-per-value-but-stable, we emit one normalized row per
      # rrset, joining values into `content` and exposing the full list
      # under `values`. (Alias rrsets carry no <ResourceRecord>/<TTL>;
      # those are skipped — they can't be managed via this content-based
      # contract.)
      def normalize_record(rr, zone_id)
        type = rr.at_xpath("Type")&.text.to_s
        name = rr.at_xpath("Name")&.text.to_s
        ttl  = rr.at_xpath("TTL")&.text
        values = rr.xpath("ResourceRecords/ResourceRecord/Value").map(&:text)

        return [] if values.empty? # alias / unsupported rrset

        [ {
          id: build_record_id(type, name),
          zone_id: strip_zone_prefix(zone_id),
          type: type,
          name: name,
          content: values.join(" "),
          values: values,
          ttl: ttl&.to_i,
          proxied: false
        }.compact ]
      end

      def change_status(doc)
        return nil unless doc.respond_to?(:at_xpath)
        doc.at_xpath("//ChangeInfo/Status")&.text
      end

      def change_id(doc)
        return nil unless doc.respond_to?(:at_xpath)
        doc.at_xpath("//ChangeInfo/Id")&.text
      end

      # ── Helpers ──────────────────────────────────────────────────────

      # Synthetic record id: Route53 has no native id, so (type, name)
      # is the natural key. Name is normalized to a trailing dot to match
      # what Route53 returns.
      def build_record_id(type, name)
        "#{type.to_s.upcase}:#{trailing_dot(name)}"
      end

      def split_record_id(record_id)
        type, name = record_id.to_s.split(":", 2)
        [ type.to_s.upcase, name.to_s ]
      end

      # Route53 stores names with a trailing dot ("example.com."). The
      # operator typically passes a bare/relative name; turn it into a
      # FQDN within the zone.
      def fqdn(name, zone_id)
        n = name.to_s.strip
        return zone_apex(zone_id) if n.empty? || n == "@"
        return trailing_dot(n) if n.include?(".") && fqdn_within_zone?(n, zone_id)
        trailing_dot("#{n}.#{zone_apex_bare(zone_id)}")
      end

      # We don't have the zone name from the id alone (id is opaque Z…),
      # so when the caller passes a name that already looks fully
      # qualified we trust it; otherwise we can't synthesize the apex and
      # fall back to the bare name with a trailing dot.
      def fqdn_within_zone?(_name, _zone_id)
        true
      end

      def zone_apex(_zone_id)
        nil
      end

      def zone_apex_bare(_zone_id)
        ""
      end

      def trailing_dot(name)
        n = name.to_s
        n.end_with?(".") ? n : "#{n}."
      end

      # Compare names tolerant of trailing dots on either side.
      def zone_name_matches?(a, b)
        a.to_s.chomp(".") == b.to_s.chomp(".")
      end

      def strip_zone_prefix(zone_id)
        zone_id.to_s.sub(%r{\A/hostedzone/}, "")
      end

      def normalize_ttl(ttl)
        t = ttl.to_i
        return 300 if t <= 1 # Cloudflare "auto"=1 → Route53 sane default
        t
      end

      def escape(s)
        ERB::Util.url_encode(s.to_s)
      end

      def xml_escape(s)
        s.to_s
         .gsub("&", "&amp;")
         .gsub("<", "&lt;")
         .gsub(">", "&gt;")
         .gsub('"', "&quot;")
      end

      def validate_record_type!(type)
        return if ALLOWED_RECORD_TYPES.include?(type.to_s.upcase)
        raise ApiError, "Unsupported record type #{type.inspect} on Route53; allowed: #{ALLOWED_RECORD_TYPES.inspect}"
      end
    end
  end
end
