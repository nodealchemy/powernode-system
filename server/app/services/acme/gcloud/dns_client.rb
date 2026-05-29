# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require "base64"
require "openssl"

module Acme
  module Gcloud
    # Google Cloud DNS adapter. Conforms to the Acme::DnsClient contract
    # so the records controller doesn't branch on provider.
    #
    # Auth: OAuth2 service-account JWT-bearer flow. The operator stores a
    # service-account JSON key (the same artifact Lego's `gcloud` provider
    # consumes for DNS-01) plus the GCP project id. We parse the JSON for
    # client_email + private_key, mint a short-lived RS256 JWT, and
    # exchange it at https://oauth2.googleapis.com/token for a bearer
    # access_token which is then cached on the instance.
    #
    # Google Cloud DNS quirks:
    #   - "Zones" are "managedZones". The opaque id is `name` (a slug),
    #     while the apex domain lives in `dnsName` (trailing-dot FQDN).
    #     We map id -> name and name -> dnsName at the contract boundary.
    #   - Records are "rrsets" — there is no per-record id. A record is
    #     keyed by (name, type) and holds an array of rrdatas. We surface
    #     a synthetic id of "<name>|<type>" so callers have a stable
    #     handle for get/delete.
    #   - Records are never edited directly; all mutations go through a
    #     "change" (POST /changes) carrying `additions` / `deletions`.
    #     update = delete-old + add-new in a single change.
    #   - No "proxied" concept (raw DNS) — that flag is ignored.
    #   - TTL is required on every rrset; the Cloudflare "auto"=1 sentinel
    #     is mapped to a sane default (300s).
    #
    # Plan reference: E (multi-provider DNS adapters).
    class DnsClient
      OAUTH_TOKEN_URL = "https://oauth2.googleapis.com/token"
      DNS_BASE_URL = "https://dns.googleapis.com/dns/v1"
      OAUTH_SCOPE = "https://www.googleapis.com/auth/ndev.clouddns.readwrite"
      JWT_GRANT_TYPE = "urn:ietf:params:oauth:grant-type:jwt-bearer"
      TOKEN_TTL = 3600
      DEFAULT_TTL = 300
      DEFAULT_TIMEOUT = 10
      ALLOWED_RECORD_TYPES = %w[A AAAA CNAME TXT MX SRV NS CAA PTR].freeze

      Result = ::Acme::Cloudflare::DnsClient::Result

      class ApiError < ::Acme::Cloudflare::DnsClient::ApiError; end

      # Accepts either explicit keyword credentials or a `credentials:`
      # hash. The DnsClient factory currently forwards `api_token:`; gcloud
      # needs `service_account_json` + `project_id` instead, so both shapes
      # are supported (mirrors the multi-field Porkbun adapter):
      #
      #   Acme::Gcloud::DnsClient.new(service_account_json: json, project_id: "p")
      #   Acme::Gcloud::DnsClient.new(credentials: { "service_account_json" => json, "project_id" => "p" })
      def initialize(credentials: nil, service_account_json: nil, project_id: nil,
                     api_token: nil, timeout: DEFAULT_TIMEOUT, logger: nil)
        _ = api_token # the DnsClient factory always passes api_token; gcloud uses service_account_json
        creds = symbolize(credentials)
        @service_account_json = service_account_json || creds[:service_account_json]
        @project_id = project_id || creds[:project_id]

        raise ArgumentError, "service_account_json is required" if @service_account_json.to_s.strip.empty?
        raise ArgumentError, "project_id is required" if @project_id.to_s.strip.empty?

        @timeout = timeout
        @logger = logger || ::Rails.logger
        @access_token = nil
        @token_expires_at = nil
      end

      def list_zones(name: nil, per_page: 50, page: 1)
        # Google paginates via opaque pageToken, not page numbers; we honor
        # maxResults and ignore the integer page (contract compatibility).
        _ = page
        params = { maxResults: per_page }
        params[:dnsName] = normalize_dns_name(name) if name.present?
        result = get("/managedZones", params: params)
        return result unless result.ok?

        zones = Array(result.data["managedZones"]).map { |z| normalize_zone(z) }
        Result.new(ok: true, data: zones, http_status: result.http_status)
      end

      def get_zone(zone_id)
        result = get("/managedZones/#{escape(zone_id)}")
        return result unless result.ok?
        Result.new(ok: true, data: normalize_zone(result.data), http_status: result.http_status)
      end

      def list_records(zone_id, type: nil, name: nil, per_page: 100, page: 1)
        _ = page
        params = { maxResults: per_page }
        params[:type] = type.to_s.upcase if type.present?
        params[:name] = normalize_dns_name(name) if name.present?
        result = get("/managedZones/#{escape(zone_id)}/rrsets", params: params)
        return result unless result.ok?

        recs = Array(result.data["rrsets"]).map { |r| normalize_record(r, zone_id) }
        Result.new(ok: true, data: recs, http_status: result.http_status)
      end

      # Google has no GET-single-rrset endpoint; we list and match on the
      # synthetic "<name>|<type>" id (or a bare name) to find the rrset.
      def get_record(zone_id, record_id)
        rname, rtype = split_record_id(record_id)
        result = list_records(zone_id, type: rtype, name: rname)
        return result unless result.ok?

        match = Array(result.data).find { |r| r[:id] == record_id.to_s || r[:name] == normalize_dns_name(rname) }
        unless match
          return Result.new(ok: false, error: "Record #{record_id.inspect} not found in zone #{zone_id}",
                            http_status: 404)
        end
        Result.new(ok: true, data: match, http_status: result.http_status)
      end

      def create_record(zone_id, type:, name:, content:, ttl: 1, proxied: false, **extras)
        validate_record_type!(type)
        _ = proxied
        _ = extras
        rrset = build_rrset(type: type, name: name, content: content, ttl: ttl)

        result = post("/managedZones/#{escape(zone_id)}/changes", body: { additions: [ rrset ] })
        return result unless result.ok?
        added = Array(result.data["additions"]).first || rrset
        Result.new(ok: true, data: normalize_record(added, zone_id), http_status: result.http_status)
      end

      # Google edits rrsets through a single change carrying both the
      # deletion of the existing rrset and the addition of the new one.
      def update_record(zone_id, record_id, attrs)
        if attrs[:type].present?
          validate_record_type!(attrs[:type])
        end

        existing = get_record(zone_id, record_id)
        return existing unless existing.ok?
        old = existing.data

        new_type    = (attrs[:type].presence || old[:type]).to_s.upcase
        new_name    = attrs[:name].presence || old[:name]
        new_content = attrs[:content].presence || old[:content]
        new_ttl     = attrs[:ttl].presence || old[:ttl]

        validate_record_type!(new_type)
        deletion = build_rrset(type: old[:type], name: old[:name], content: old[:content], ttl: old[:ttl])
        addition = build_rrset(type: new_type, name: new_name, content: new_content, ttl: new_ttl)

        result = post("/managedZones/#{escape(zone_id)}/changes",
                      body: { deletions: [ deletion ], additions: [ addition ] })
        return result unless result.ok?
        added = Array(result.data["additions"]).first || addition
        Result.new(ok: true, data: normalize_record(added, zone_id), http_status: result.http_status)
      end

      def delete_record(zone_id, record_id)
        existing = get_record(zone_id, record_id)
        return existing unless existing.ok?
        old = existing.data
        deletion = build_rrset(type: old[:type], name: old[:name], content: old[:content], ttl: old[:ttl])

        result = post("/managedZones/#{escape(zone_id)}/changes", body: { deletions: [ deletion ] })
        return result unless result.ok?
        Result.new(ok: true, data: { deleted: true }, http_status: result.http_status)
      end

      private

      # ── rrset construction / normalization ───────────────────────────

      def build_rrset(type:, name:, content:, ttl:)
        {
          name: normalize_dns_name(name),
          type: type.to_s.upcase,
          ttl: normalize_ttl(ttl),
          rrdatas: rrdatas_for(type, content)
        }
      end

      # rrdatas is always an array. Callers may pass a single value or an
      # already-split array; TXT values must be wrapped in quotes per the
      # Google API contract.
      def rrdatas_for(type, content)
        values = content.is_a?(Array) ? content : [ content ]
        values = values.map(&:to_s)
        if type.to_s.upcase == "TXT"
          values = values.map { |v| quote_txt(v) }
        end
        values
      end

      def quote_txt(value)
        return value if value.start_with?('"') && value.end_with?('"')
        %("#{value.gsub('"', '\\"')}")
      end

      def normalize_zone(z)
        {
          id: z["name"].to_s,                 # opaque managedZone slug
          name: strip_trailing_dot(z["dnsName"]),
          status: "active",
          ttl: z["defaultTtl"] || z["ttl"],
          description: z["description"],
          name_servers: z["nameServers"]
        }.compact
      end

      def normalize_record(r, zone_id)
        rrdatas = Array(r["rrdatas"])
        type = r["type"].to_s
        content = type.upcase == "TXT" ? rrdatas.map { |v| unquote_txt(v) } : rrdatas
        content = content.first if content.size == 1
        fqdn = strip_trailing_dot(r["name"])
        {
          id: "#{r['name']}|#{type}",
          zone_id: zone_id.to_s,
          zone_name: zone_id.to_s,
          type: type,
          name: fqdn,
          content: content,
          ttl: r["ttl"],
          proxied: false
        }.compact
      end

      def unquote_txt(value)
        s = value.to_s
        return s.gsub('\\"', '"') unless s.start_with?('"') && s.end_with?('"')
        s[1..-2].to_s.gsub('\\"', '"')
      end

      # The synthetic record id is "<rrset_name>|<TYPE>"; tolerate a bare
      # name (no pipe) for callers that only know the host.
      def split_record_id(record_id)
        s = record_id.to_s
        if s.include?("|")
          name, type = s.split("|", 2)
          [ name, type.to_s.upcase.presence ]
        else
          [ s, nil ]
        end
      end

      # ── OAuth2 JWT-bearer ────────────────────────────────────────────

      def access_token
        return @access_token if @access_token && @token_expires_at && Time.now.to_i < @token_expires_at

        token = mint_access_token!
        @access_token = token
        token
      end

      def mint_access_token!
        sa = JSON.parse(@service_account_json.to_s)
        client_email = sa["client_email"]
        private_key_pem = sa["private_key"]
        if client_email.to_s.empty? || private_key_pem.to_s.empty?
          raise ApiError, "service_account_json missing client_email or private_key"
        end

        iat = Time.now.to_i
        exp = iat + TOKEN_TTL
        header = { alg: "RS256", typ: "JWT" }
        claims = {
          iss: client_email,
          scope: OAUTH_SCOPE,
          aud: OAUTH_TOKEN_URL,
          iat: iat,
          exp: exp
        }

        signing_input = "#{base64url(header.to_json)}.#{base64url(claims.to_json)}"
        key = OpenSSL::PKey::RSA.new(private_key_pem)
        signature = key.sign(OpenSSL::Digest::SHA256.new, signing_input)
        assertion = "#{signing_input}.#{base64url(signature)}"

        response = exchange_assertion(assertion)
        token = response["access_token"]
        raise ApiError, "OAuth token exchange returned no access_token" if token.to_s.empty?

        @token_expires_at = exp - 60 # refresh a minute early
        token
      rescue JSON::ParserError => e
        raise ApiError, "service_account_json is not valid JSON: #{e.message}"
      end

      def exchange_assertion(assertion)
        uri = URI(OAUTH_TOKEN_URL)
        req = Net::HTTP::Post.new(uri)
        req["Content-Type"] = "application/x-www-form-urlencoded"
        req["Accept"] = "application/json"
        req.body = URI.encode_www_form(grant_type: JWT_GRANT_TYPE, assertion: assertion)

        response = http_for(uri).request(req)
        body = response.body.to_s
        parsed = body.empty? ? {} : JSON.parse(body)
        unless response.is_a?(Net::HTTPSuccess)
          msg = parsed["error_description"] || parsed["error"] || "HTTP #{response.code}"
          raise ApiError, "Google OAuth token exchange failed: #{msg}"
        end
        parsed
      rescue JSON::ParserError
        raise ApiError, "Google OAuth token exchange returned invalid JSON (HTTP #{response&.code})"
      end

      # ── DNS HTTP plumbing ────────────────────────────────────────────

      def project_path
        "/projects/#{escape(@project_id)}"
      end

      def get(path, params: {})
        uri = URI("#{DNS_BASE_URL}#{project_path}#{path}")
        uri.query = URI.encode_www_form(params) if params.any?
        request(Net::HTTP::Get.new(uri))
      end

      def post(path, body:)
        uri = URI("#{DNS_BASE_URL}#{project_path}#{path}")
        req = Net::HTTP::Post.new(uri)
        req["Content-Type"] = "application/json"
        req.body = body.to_json
        request(req)
      end

      def request(req)
        token = access_token
        req["Authorization"] = "Bearer #{token}"
        req["Accept"] = "application/json"

        response = http_for(req.uri).request(req)
        parse_response(response)
      rescue ApiError => e
        # Auth-mint failures surface as a Result so callers don't have to
        # rescue separately from transport errors.
        Result.new(ok: false, error: e.message, http_status: e.http_status)
      rescue Net::OpenTimeout, Net::ReadTimeout => e
        Result.new(ok: false, error: "Google Cloud DNS API timeout: #{e.message}")
      rescue StandardError => e
        @logger.error("[Acme::Gcloud::DnsClient] #{e.class}: #{e.message}")
        Result.new(ok: false, error: "Google Cloud DNS API error: #{e.message}")
      end

      def http_for(uri)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.read_timeout = @timeout
        http.open_timeout = @timeout
        http
      end

      # Google error envelope:
      #   { error: { code: 404, message: "...", errors: [...] } }
      def parse_response(response)
        if response.is_a?(Net::HTTPNoContent)
          return Result.new(ok: true, data: {}, http_status: 204)
        end

        body = response.body.to_s
        parsed = body.empty? ? {} : JSON.parse(body)

        if response.is_a?(Net::HTTPSuccess)
          Result.new(ok: true, data: parsed, http_status: response.code.to_i)
        else
          err = parsed["error"] || {}
          msg = err["message"] || "Google Cloud DNS returned HTTP #{response.code}"
          Result.new(ok: false, error: msg, http_status: response.code.to_i,
                     cf_errors: Array(err["errors"]).map { |e| { code: e["reason"], message: e["message"] } })
        end
      rescue JSON::ParserError
        Result.new(ok: false,
                   error: "Invalid JSON from Google Cloud DNS (HTTP #{response.code}): #{response.body.to_s[0, 200]}",
                   http_status: response.code.to_i)
      end

      # ── helpers ──────────────────────────────────────────────────────

      def base64url(data)
        Base64.urlsafe_encode64(data, padding: false)
      end

      def escape(s)
        ERB::Util.url_encode(s.to_s)
      end

      def validate_record_type!(type)
        return if ALLOWED_RECORD_TYPES.include?(type.to_s.upcase)
        raise ApiError, "Unsupported record type #{type.inspect} on Google Cloud DNS; " \
                        "allowed: #{ALLOWED_RECORD_TYPES.inspect}"
      end

      # Google DNS names are FQDNs with a trailing dot. Accept either form
      # from callers and emit the canonical trailing-dot shape.
      def normalize_dns_name(name)
        s = name.to_s.strip
        return s if s.empty?
        s.end_with?(".") ? s : "#{s}."
      end

      def strip_trailing_dot(name)
        name.to_s.sub(/\.\z/, "")
      end

      def normalize_ttl(ttl)
        t = ttl.to_i
        return DEFAULT_TTL if t <= 1
        t
      end

      def symbolize(hash)
        return {} unless hash.is_a?(Hash)
        hash.each_with_object({}) { |(k, v), acc| acc[k.to_sym] = v }
      end
    end
  end
end
