# frozen_string_literal: true

module System
  module Webhooks
    # Shared, POLICY-FREE primitives for the System extension's inbound
    # webhook receivers (Gitea module, module SBOM, package build, disk
    # image). DRYs the HMAC compute/compare + the gitea-family request
    # parsing/response plumbing that was copy-pasted across controllers.
    #
    # IMPORTANT — this concern is deliberately policy-free. It does NOT
    # decide fail-open vs fail-closed, does NOT resolve which secret to
    # use, and does NOT read a controller-specific signature header.
    # Each controller keeps its own secret resolution and accept/reject
    # policy inline; it only routes the mechanical pieces through here.
    #
    # The single standardization this introduces: ALL HMAC comparisons go
    # through ActiveSupport::SecurityUtils.secure_compare (constant-time).
    # Gitea/SBOM previously used Rack::Utils.secure_compare — behavior is
    # identical (both are constant-time and both return false, never raise,
    # on a length mismatch), so this is not a behavior change.
    module HmacVerification
      extend ActiveSupport::Concern

      private

      # HMAC-SHA256 over the raw body, hex-encoded. OpenSSL treats the
      # digest name case-insensitively ("sha256" == "SHA256").
      def hmac_hex(secret, body)
        OpenSSL::HMAC.hexdigest("sha256", secret, body)
      end

      # Constant-time comparison of an expected hex digest against a
      # provided signature header value. Tolerates a leading "sha256="
      # prefix (GitHub-style senders). Returns false — never raises — on
      # a malformed / length-mismatched signature, so a bad header can
      # never escalate to a 500.
      def secure_match?(expected_hex, provided)
        provided = provided.to_s.sub(/\Asha256=/, "")
        ActiveSupport::SecurityUtils.secure_compare(expected_hex.to_s, provided)
      rescue StandardError
        false
      end

      # Returns the first present signature header value among the given
      # header names (e.g. "X-Gitea-Signature", "X-Hub-Signature-256").
      def signature_from_headers(*header_names)
        header_names.each do |name|
          value = request.headers[name]
          return value if value.present?
        end
        nil
      end

      # Reads the raw request body into @raw_body and parses it as JSON
      # with indifferent access. Returns nil on a blank body or invalid
      # JSON (logging the parse failure under the caller's log tag), so
      # the receiver can ack 200 instead of 500-ing on garbage input.
      def parse_json_request_body(log_tag:)
        body = request.body.read
        return nil if body.blank?

        @raw_body = body
        JSON.parse(body).with_indifferent_access
      rescue JSON::ParserError => e
        Rails.logger.warn "#{log_tag} Invalid JSON payload: #{e.message}"
        nil
      end

      # Standard gitea-family webhook ack: 200 with a {status, message}
      # body. Gitea ignores the message; humans read it in logs.
      def render_ok(message = "OK")
        render json: { status: "ok", message: message }, status: :ok
      end
    end
  end
end
