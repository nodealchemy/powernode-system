# frozen_string_literal: true

# Builds the Traefik-style mTLS client-cert header that
# Api::V1::System::WorkerApi::BaseController#authenticate_worker! reads.
#
# Stage 8b deploys the Sidekiq worker as a NodeInstance: the reverse
# proxy verifies the worker's client cert on the single websecure (:443)
# entrypoint (optional mTLS — VerifyClientCertIfGiven) and forwards the
# verified subject CN (= the worker's node_instance_id) via
# X-Forwarded-Tls-Client-Cert-Info. The legacy X-Worker-Token header is
# gone — request specs must present the cert header instead.
module WorkerMtlsAuthHelpers
  # Header hash that authenticates `worker` against the worker_api /
  # node_api mTLS controllers. CN = worker.node_instance_id, URL-encoded
  # in the Subject="CN=..." shape the passTLSClientCert middleware emits.
  def worker_mtls_headers(worker)
    cn = worker.node_instance_id
    { "X-Forwarded-Tls-Client-Cert-Info" => CGI.escape(%(Subject="CN=#{cn}")) }
  end
end

RSpec.configure do |config|
  config.include WorkerMtlsAuthHelpers, type: :request
end
