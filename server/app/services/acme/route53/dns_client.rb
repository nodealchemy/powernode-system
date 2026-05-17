# frozen_string_literal: true

module Acme
  module Route53
    # Route53 stub. Returns a clear unsupported-result on every call
    # rather than silently failing or pulling in the aws-sdk-route53
    # gem. Route53 uses AWS SigV4 signing which requires per-request
    # signature computation — moderate work, deferred until operator
    # demand surfaces.
    #
    # ACME DNS-01 challenge support via Lego works for Route53 already
    # (Lego ships its own SigV4 signer); this gap only affects the
    # operator-facing record CRUD surface, not cert issuance.
    #
    # Plan reference: E4.
    class DnsClient
      Result = ::Acme::Cloudflare::DnsClient::Result

      UNSUPPORTED_MESSAGE = "Route53 record management is not yet implemented in the operator UI. " \
                            "ACME DNS-01 challenges still work via Lego. For record CRUD today, " \
                            "use Cloudflare/DigitalOcean/Hetzner credentials or manage Route53 " \
                            "directly via AWS Console / CLI."

      def initialize(api_token:, **_opts)
        # Accept the constructor signature even though we don't use it
        @api_token = api_token
      end

      %i[list_zones get_zone list_records get_record
         create_record update_record delete_record].each do |method_name|
        define_method(method_name) do |*_args, **_kwargs|
          Result.new(ok: false, error: UNSUPPORTED_MESSAGE, http_status: 501)
        end
      end
    end
  end
end
