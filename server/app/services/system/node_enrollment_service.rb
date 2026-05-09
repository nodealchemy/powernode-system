# frozen_string_literal: true

module System
  # Validates a bootstrap token, signs the supplied CSR via InternalCaService,
  # records the issued NodeCertificate, marks the token consumed, and returns
  # the cert + chain to the caller.
  #
  # Reference: Golden Eclipse plan — node_api Contract (POST /enroll); M0.O.
  class NodeEnrollmentService
    Result = Struct.new(:ok?, :error, :node_certificate, :cert_pem, :ca_chain_pem,
                        :node_instance, keyword_init: true)

    class EnrollmentError < StandardError; end

    DEFAULT_TTL_SECONDS = InternalCaService::DEFAULT_TTL_SECONDS

    def self.enroll!(bootstrap_token_plaintext:, csr_pem:, agent_version: nil,
                     dmi_uuid: nil, source_ip: nil, ttl_seconds: DEFAULT_TTL_SECONDS)
      new.enroll!(
        bootstrap_token_plaintext: bootstrap_token_plaintext,
        csr_pem: csr_pem,
        agent_version: agent_version,
        dmi_uuid: dmi_uuid,
        source_ip: source_ip,
        ttl_seconds: ttl_seconds
      )
    end

    # Refresh the cert for an already-enrolled instance. Authenticated
    # by the existing mTLS cert (caller passes current_instance from
    # the controller chain). Bootstrap tokens are NOT used here —
    # they are single-use by design.
    #
    # Re-issues with the same CN (instance.mtls_subject) so the agent's
    # identity stays stable across rotations. The old NodeCertificate
    # row is left in place; the platform's audit log keeps the full
    # rotation history. In-flight requests on the old cert continue to
    # work until that cert's NotAfter.
    #
    # Phase 1 of the agent stub implementation plan.
    def self.refresh!(node_instance:, csr_pem:, agent_version: nil,
                      ttl_seconds: DEFAULT_TTL_SECONDS)
      new.refresh!(
        node_instance: node_instance,
        csr_pem: csr_pem,
        agent_version: agent_version,
        ttl_seconds: ttl_seconds
      )
    end

    def refresh!(node_instance:, csr_pem:, agent_version: nil,
                 ttl_seconds: DEFAULT_TTL_SECONDS)
      return failure("node instance required") unless node_instance
      return failure("csr_pem required") if csr_pem.blank?

      common_name = node_instance.mtls_subject.presence || node_instance.id

      issued = ::System::InternalCaService.issue_certificate(
        csr_pem: csr_pem,
        ttl_seconds: ttl_seconds,
        common_name: common_name
      )

      cert_record = ::System::NodeCertificate.create!(
        node_instance: node_instance,
        serial: issued[:serial],
        subject: issued[:subject] || "CN=#{common_name}",
        not_before: issued[:not_before] || Time.current,
        not_after:  issued[:not_after]  || (Time.current + ttl_seconds),
        issuer_subject: parse_issuer(issued[:ca_chain_pem])
      )

      if agent_version.present?
        node_instance.update!(agent_version: agent_version)
      end

      Result.new(
        ok?: true,
        node_certificate: cert_record,
        cert_pem:     issued[:cert_pem],
        ca_chain_pem: issued[:ca_chain_pem] || ::System::InternalCaService.ca_chain_pem,
        node_instance: node_instance
      )
    rescue ::System::InternalCaService::CaError, ::System::InternalCaService::CsrError => e
      failure("CSR/CA failure: #{e.message}")
    rescue ::ActiveRecord::RecordInvalid => e
      failure("certificate persistence failed: #{e.record.errors.full_messages.join('; ')}")
    end

    def enroll!(bootstrap_token_plaintext:, csr_pem:, agent_version: nil,
                dmi_uuid: nil, source_ip: nil, ttl_seconds: DEFAULT_TTL_SECONDS)
      token = ::System::BootstrapToken.find_active_by_plaintext(bootstrap_token_plaintext)
      return failure("invalid or expired bootstrap token") unless token

      instance = resolve_instance(token: token, dmi_uuid: dmi_uuid)
      return failure("intended instance not found") unless instance

      common_name = token.intended_subject.presence || instance.id

      issued = ::System::InternalCaService.issue_certificate(
        csr_pem: csr_pem,
        ttl_seconds: ttl_seconds,
        common_name: common_name
      )

      cert_record = ::System::NodeCertificate.create!(
        node_instance: instance,
        serial: issued[:serial],
        subject: issued[:subject] || "CN=#{common_name}",
        not_before: issued[:not_before] || Time.current,
        not_after:  issued[:not_after]  || (Time.current + ttl_seconds),
        issuer_subject: parse_issuer(issued[:ca_chain_pem])
      )

      ::ActiveRecord::Base.transaction do
        token.consume!(from_ip: source_ip)
        instance.update!(
          agent_version: agent_version.presence || instance.agent_version,
          mtls_subject: common_name,
          enrollment_token: token
        )
      end

      Result.new(
        ok?: true,
        node_certificate: cert_record,
        cert_pem:     issued[:cert_pem],
        ca_chain_pem: issued[:ca_chain_pem] || ::System::InternalCaService.ca_chain_pem,
        node_instance: instance
      )
    rescue ::System::BootstrapToken::InvalidConsumption => e
      failure(e.message)
    rescue ::System::InternalCaService::CaError, ::System::InternalCaService::CsrError => e
      failure("CSR/CA failure: #{e.message}")
    rescue ::ActiveRecord::RecordInvalid => e
      failure("certificate persistence failed: #{e.record.errors.full_messages.join('; ')}")
    end

    private

    # Resolve which NodeInstance this enrollment is for. Three strategies, in
    # priority order:
    # 1. Token has node_instance_id set → use that.
    # 2. dmi_uuid maps to an existing NodeInstance.id → use that.
    # 3. Token is bound to a node only → pick the first pending instance of
    #    that node (covers the "first boot of provisioned instance" case).
    def resolve_instance(token:, dmi_uuid:)
      return token.node_instance if token.node_instance

      if dmi_uuid.present? && (by_dmi = ::System::NodeInstance.find_by(id: dmi_uuid))
        return by_dmi if by_dmi.node_id == token.node_id
      end

      token.node.node_instances.where(status: %w[pending provisioning starting running]).first
    end

    def parse_issuer(ca_chain_pem)
      return nil if ca_chain_pem.blank?

      OpenSSL::X509::Certificate.new(ca_chain_pem).subject.to_s
    rescue OpenSSL::X509::CertificateError
      nil
    end

    def failure(message)
      Result.new(ok?: false, error: message)
    end
  end
end
