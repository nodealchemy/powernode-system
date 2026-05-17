# frozen_string_literal: true

require "net/http"
require "openssl"
require "uri"
require "json"

module Federation
  # Outbound HTTP client for calling a remote FederationPeer's
  # federation_api endpoints. Used by:
  #
  #   - PeerCatalogController (proxy /federation_api/service_catalog)
  #   - PeerSubscriptionsController (proxy /federation_api/subscriptions)
  #   - (future) FederationManager AI Skill periodic ops
  #
  # mTLS posture: in production this client must present a client cert
  # signed by the platform's internal CA so the remote peer's
  # BaseController#authenticate_federation_peer! recognizes us.
  # The cert lives at @peer.node_certificate (the cert the OPERATOR
  # minted for US when we federated with them; we hold a copy).
  #
  # For v1 + tests, the HTTPClient interface is stub-friendly:
  # tests inject a fake client that returns canned responses.
  # Real mTLS wiring is a P2.5.7 acceptance-time concern.
  #
  # Plan reference: Decentralized Federation §J + §L.3 + P4.6.8e.
  class PeerClient
    class ClientError < StandardError; end
    class ConnectionError < ClientError; end
    class HttpError < ClientError
      attr_reader :status
      def initialize(message, status:)
        super(message)
        @status = status
      end
    end

    # Minimal interface that real-Net::HTTP, Faraday, or test stubs
    # all satisfy. The real default uses Net::HTTP under the hood.
    DEFAULT_TIMEOUT_SECONDS = 10

    def initialize(peer:, http_client: nil, timeout_seconds: DEFAULT_TIMEOUT_SECONDS)
      @peer = peer
      @http_client = http_client || NetHttpAdapter.new(
        timeout_seconds: timeout_seconds,
        client_cert_pem: extract_client_cert_pem,
        client_key_pem:  extract_client_key_pem
      )
    end

    # Fetches the peer's service catalog. Returns a parsed Ruby hash
    # matching the federation_api/service_catalog response shape:
    #   { "offerings" => [...], "generated_at" => "..." }
    def fetch_catalog
      response = @http_client.get(
        url_for("/api/v1/system/federation_api/service_catalog"),
        headers: mtls_headers
      )
      parsed_data(response, context: "GET catalog from peer #{@peer.id}")
    end

    # POSTs to the peer's federation_api/subscriptions endpoint.
    # Returns the parsed connection details hash:
    #   { "grant_id", "backend_host", "backend_port", "protocol",
    #     "expires_at", "ttl_seconds", "service_offering_id" }
    def post_subscription(slug:, local_hostname:, ttl_days: nil)
      body = { slug: slug, local_hostname: local_hostname }
      body[:ttl_days] = ttl_days if ttl_days

      response = @http_client.post(
        url_for("/api/v1/system/federation_api/subscriptions"),
        body: body.to_json,
        headers: mtls_headers.merge("Content-Type" => "application/json")
      )
      parsed_data(response, context: "POST subscription to peer #{@peer.id}")
    end

    # DELETEs an existing subscription grant on the peer.
    def delete_subscription(grant_id:)
      response = @http_client.delete(
        url_for("/api/v1/system/federation_api/subscriptions/#{grant_id}"),
        headers: mtls_headers
      )
      parsed_data(response, context: "DELETE subscription #{grant_id} on peer #{@peer.id}")
    end

    private

    # Returns the client-cert PEM for outbound mTLS, or nil when the peer's
    # cert/key haven't been wired yet (federation P2.5 — the CSR-and-store
    # flow that populates `peer.node_certificate.credentials` is still
    # scaffolded; see accept_controller.rb). When nil, NetHttpAdapter
    # falls back to plaintext; a remote peer enforcing client-cert
    # verification will reject the call with ConnectionError, which is the
    # right failure mode (vs silent insecure traffic).
    def extract_client_cert_pem
      cert_record = peer_node_certificate
      return nil unless cert_record
      creds = safe_credentials(cert_record)
      creds && (creds[:cert_pem] || creds["cert_pem"])
    end

    def extract_client_key_pem
      cert_record = peer_node_certificate
      return nil unless cert_record
      creds = safe_credentials(cert_record)
      creds && (creds[:private_key_pem] || creds["private_key_pem"])
    end

    def peer_node_certificate
      return nil unless @peer.respond_to?(:node_certificate)
      @peer.node_certificate
    rescue StandardError => e
      Rails.logger.warn("[PeerClient] failed to load node_certificate for peer #{@peer.id}: #{e.class}: #{e.message}")
      nil
    end

    def safe_credentials(record)
      record.credentials
    rescue StandardError => e
      Rails.logger.warn("[PeerClient] failed to fetch credentials for peer #{@peer.id}: #{e.class}: #{e.message}")
      nil
    end

    # Picks the peer's primary endpoint URL. v1 uses the first
    # advertised endpoint (priority-ordered by Federation::EndpointProber
    # in §J); future rounds wire EndpointProber for fast-fail probing.
    def url_for(path)
      endpoint = (Array(@peer.endpoints).first || {})["url"]
      base = endpoint.presence || @peer.remote_instance_url
      raise ClientError, "Peer #{@peer.id} has no reachable URL" if base.blank?

      "#{base.chomp('/')}#{path}"
    end

    # In production, mTLS auth is handled by the underlying TLS layer
    # of the HTTP client (cert + key configured on the client). These
    # headers are supplementary metadata; the real auth happens via
    # the client cert presented during TLS handshake.
    def mtls_headers
      {
        "Accept" => "application/json",
        "User-Agent" => "Powernode-FederationClient/1.0 (peer-id:#{@peer.id})"
      }
    end

    def parsed_data(response, context:)
      raise ConnectionError, "no response (#{context})" if response.nil?

      status = response[:status] || response["status"]
      body   = response[:body]   || response["body"]

      if status.nil? || status.to_i.zero? || status.to_i >= 500
        raise ConnectionError, "remote server error (#{context}): status=#{status}"
      end
      if status.to_i >= 400
        message = parse_error(body) || "HTTP #{status}"
        raise HttpError.new("#{context}: #{message}", status: status.to_i)
      end

      parsed = parse_json(body)
      parsed.is_a?(Hash) ? (parsed["data"] || parsed) : {}
    end

    def parse_json(body)
      return {} if body.blank?
      JSON.parse(body)
    rescue JSON::ParserError
      {}
    end

    def parse_error(body)
      JSON.parse(body.to_s)["error"] if body.present?
    rescue JSON::ParserError
      nil
    end
  end

  # Default HTTP adapter — small wrapper around Net::HTTP so tests
  # can swap in a stub. mTLS wiring takes the cert + key extracted from
  # peer.node_certificate.credentials (Vault-backed via VaultCredential
  # concern). When credentials aren't yet wired (federation P2.5 in
  # progress), this falls back to plaintext — a remote peer enforcing
  # client-cert verification will reject the call, which is the right
  # failure mode vs silent insecure traffic.
  class NetHttpAdapter
    def initialize(timeout_seconds: PeerClient::DEFAULT_TIMEOUT_SECONDS,
                   client_cert_pem: nil, client_key_pem: nil)
      @timeout         = timeout_seconds
      @client_cert_pem = client_cert_pem
      @client_key_pem  = client_key_pem
    end

    def get(url, headers: {})
      request_with(url, headers: headers) { |http, uri| http.get(uri.request_uri, headers) }
    end

    def post(url, body:, headers: {})
      request_with(url, headers: headers) { |http, uri| http.post(uri.request_uri, body, headers) }
    end

    def delete(url, headers: {})
      request_with(url, headers: headers) { |http, uri|
        req = Net::HTTP::Delete.new(uri.request_uri)
        headers.each { |k, v| req[k] = v }
        http.request(req)
      }
    end

    private

    def request_with(url, headers: {})
      uri = URI.parse(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.read_timeout = @timeout
      http.open_timeout = @timeout
      configure_mtls(http)
      response = yield(http, uri)
      { status: response.code.to_i, body: response.body }
    rescue Errno::ECONNREFUSED, Errno::ETIMEDOUT, SocketError, Net::OpenTimeout, Net::ReadTimeout => e
      { status: 0, body: %({"error":"#{e.class}: #{e.message}"}) }
    end

    # Configures Net::HTTP for mTLS when cert + key are present. Partial
    # config (one without the other) logs and falls back to plaintext —
    # this should never happen with a correctly-stored peer credential
    # but is defended against because the credential write path is still
    # under construction (P2.5).
    def configure_mtls(http)
      return unless http.use_ssl?
      return if @client_cert_pem.blank? && @client_key_pem.blank?

      unless @client_cert_pem.present? && @client_key_pem.present?
        Rails.logger.warn(
          "[PeerClient] partial mTLS config — cert_pem=#{@client_cert_pem.present?}, " \
          "key_pem=#{@client_key_pem.present?}; falling back to plaintext"
        )
        return
      end

      http.cert        = OpenSSL::X509::Certificate.new(@client_cert_pem)
      http.key         = OpenSSL::PKey.read(@client_key_pem)
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
    rescue OpenSSL::X509::CertificateError, OpenSSL::PKey::PKeyError => e
      Rails.logger.error("[PeerClient] mTLS config failed: #{e.class}: #{e.message}")
      # Fall back to plaintext; remote will reject if it requires mTLS
    end
  end
end
