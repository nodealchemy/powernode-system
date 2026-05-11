# frozen_string_literal: true

module System
  # Triggers a CI build of a NodeModule by computing the effective rsync_spec +
  # package_spec for a deployment context, then dispatching the Gitea Actions
  # workflow with those values as workflow_dispatch inputs.
  #
  # Adapter pattern: LocalDispatchAdapter (test/dev — records dispatches in
  # memory for assertions) and GiteaDispatchAdapter (production — POSTs to
  # Gitea's workflow_dispatch endpoint).
  #
  # Reference: Golden Eclipse plan M1 — module supply chain dispatch.
  class ModuleBuildDispatchService
    Result = Struct.new(:ok?, :error, :dispatch_id, :rsync_spec, :package_spec, :fingerprint,
                        keyword_init: true)

    class DispatchError < StandardError; end

    DEFAULT_WORKFLOW_FILENAME = "build.yaml"
    DEFAULT_REF               = "main"

    class << self
      def adapter
        @adapter ||= build_adapter
      end

      def adapter=(replacement)
        @adapter = replacement
      end

      def reset!
        @adapter = nil
      end

      def dispatch_build!(node_module:, target: nil, ref: DEFAULT_REF, workflow: DEFAULT_WORKFLOW_FILENAME)
        new.dispatch_build!(
          node_module: node_module, target: target,
          ref: ref, workflow: workflow
        )
      end

      # Dispatch a closure-batched build for a set of NodeModules materialized
      # from a single PackageRepository. Unlike dispatch_build! (which fires
      # one workflow per module via gitea_repo_full_name), this fires ONE
      # workflow per architecture that mmdebstraps the whole closure into
      # one chroot, then carves N module tarballs using each module's
      # rsync_spec. The workflow callback path is the new
      # PackageBuildWebhookController, NOT manifest_import_service.
      #
      # Returns Array<{dispatch_id:, architecture:, ok:, error:}> — one entry
      # per architecture dispatched.
      def dispatch_closure(repository:, modules:, architectures:, requested_by: nil)
        new.dispatch_closure(
          repository: repository, modules: modules,
          architectures: architectures, requested_by: requested_by
        )
      end

      private

      def build_adapter
        mode = ENV.fetch("POWERNODE_BUILD_DISPATCH_MODE", default_mode_for_env)
        case mode
        when "gitea" then GiteaDispatchAdapter.new
        when "local" then LocalDispatchAdapter.new
        else raise DispatchError, "Unknown POWERNODE_BUILD_DISPATCH_MODE: #{mode.inspect}"
        end
      end

      def default_mode_for_env
        Rails.env.production? ? "gitea" : "local"
      end
    end

    def dispatch_build!(node_module:, target: nil, ref: DEFAULT_REF, workflow: DEFAULT_WORKFLOW_FILENAME)
      return failure("node_module required") unless node_module
      return failure("module is missing gitea_repo_full_name") if node_module.gitea_repo_full_name.blank?

      compiled = ::System::RsyncSpecCompiler.compile(node_module: node_module, target: target)

      payload = {
        repository: node_module.gitea_repo_full_name,
        workflow:   workflow,
        ref:        ref,
        inputs: {
          rsync_spec:    compiled.rsync_spec,
          package_spec:  compiled.package_spec,
          fingerprint:   compiled.fingerprint,
          module_id:     node_module.id,
          module_name:   node_module.name
        }
      }

      dispatch = self.class.adapter.dispatch(payload)
      return failure("dispatch failed: #{dispatch[:error]}") unless dispatch[:ok]

      Result.new(
        ok?: true,
        dispatch_id:  dispatch[:dispatch_id],
        rsync_spec:   compiled.rsync_spec,
        package_spec: compiled.package_spec,
        fingerprint:  compiled.fingerprint
      )
    rescue StandardError => e
      Rails.logger.error("[ModuleBuildDispatchService] #{e.class}: #{e.message}")
      failure("dispatch raised: #{e.message}")
    end

    PACKAGE_BUILD_WORKFLOW   = "build-package-module.yaml"
    PACKAGE_BUILD_DEFAULT_REPO = "system/package-build" # configurable via env

    def dispatch_closure(repository:, modules:, architectures:, requested_by: nil)
      raise DispatchError, "modules required" if Array(modules).empty?
      raise DispatchError, "architectures required" if Array(architectures).empty?

      package_build_repo = ENV.fetch("POWERNODE_PACKAGE_BUILD_REPO", PACKAGE_BUILD_DEFAULT_REPO)
      closure_id = compute_closure_id(modules)
      webhook_secret = generate_webhook_secret(closure_id)
      modules_payload = modules.map do |m|
        link = m.package_module_link
        {
          module_id:        m.id,
          package_name:     link&.package_name || m.name,
          architecture:     link&.architecture,
          mask:             m.decode_spec_text(m.mask),
          file_spec_source: link&.file_spec_source || "package_query"
        }
      end

      Array(architectures).map do |arch|
        dispatch_id = "closure-#{closure_id}-#{arch}-#{SecureRandom.hex(4)}"
        payload = {
          repository: package_build_repo,
          workflow:   PACKAGE_BUILD_WORKFLOW,
          ref:        DEFAULT_REF,
          inputs: {
            closure_id:        closure_id,
            architecture:      arch,
            package_repo_url:  repository.base_url,
            package_repo_kind: repository.kind,
            package_repo_id:   repository.id,
            apt_suite:         repository.kind == "apt" ? repository.suite : nil,
            apt_components:    repository.kind == "apt" ? repository.components.join(",") : nil,
            rpm_releasever:    repository.kind != "apt" ? repository.releasever : nil,
            gpg_key_armor:     repository.signing_key_armor,
            modules_payload:   modules_payload.to_json,
            webhook_url:       webhook_callback_url,
            webhook_secret:    webhook_secret,
            requested_by:      requested_by&.id
          }
        }
        result = self.class.adapter.dispatch(payload)
        {
          dispatch_id:  result[:dispatch_id] || dispatch_id,
          architecture: arch,
          ok:           result[:ok],
          error:        result[:error]
        }
      end
    end

    private

    def compute_closure_id(modules)
      key = modules.map(&:id).sort.join("|")
      Digest::SHA256.hexdigest(key)[0, 16]
    end

    def generate_webhook_secret(closure_id)
      # HMAC the closure_id with a server-side secret. The CI workflow
      # will sign its webhook with this same secret so the controller can
      # verify the callback is genuine. The secret persists for the
      # duration of the build (the controller validates the HMAC, not
      # the secret value itself).
      OpenSSL::HMAC.hexdigest(
        "SHA256",
        ENV.fetch("POWERNODE_PACKAGE_BUILD_HMAC_KEY", "dev-package-build-secret"),
        closure_id
      )
    end

    def webhook_callback_url
      ENV.fetch(
        "POWERNODE_PACKAGE_BUILD_WEBHOOK_URL",
        "http://localhost:3000/api/v1/system/webhooks/package_build"
      )
    end

    def failure(msg)
      Result.new(ok?: false, error: msg)
    end

    # ----------------------------------------------------------------------
    # Local dispatch adapter — test/dev. Records dispatches for assertion.
    # ----------------------------------------------------------------------
    class LocalDispatchAdapter
      attr_reader :dispatched

      def initialize
        @dispatched = []
      end

      def dispatch(payload)
        dispatch_id = "local-#{SecureRandom.hex(8)}"
        @dispatched << payload.merge(dispatch_id: dispatch_id, dispatched_at: Time.current)
        { ok: true, dispatch_id: dispatch_id }
      end

      def reset!
        @dispatched.clear
      end
    end

    # ----------------------------------------------------------------------
    # Gitea dispatch adapter — production. POSTs to Gitea's workflow_dispatch
    # endpoint. Uses the per-repo OAuth/PAT that platform Gitea integration
    # stores under Devops::GitProviderCredential (not yet wired here — flagged
    # as M1 follow-up).
    # ----------------------------------------------------------------------
    class GiteaDispatchAdapter
      DEFAULT_BASE_URL = "https://registry.example.com"

      def initialize(base_url: nil, token: nil)
        @base_url = base_url || ENV.fetch("POWERNODE_GITEA_BASE_URL", DEFAULT_BASE_URL)
        @token    = token    || ENV.fetch("POWERNODE_GITEA_TOKEN", nil)
      end

      def dispatch(payload)
        return { ok: false, error: "POWERNODE_GITEA_TOKEN not set" } unless @token

        require "net/http"
        require "uri"

        repo = payload.fetch(:repository)
        workflow = payload.fetch(:workflow)
        url = URI.parse("#{@base_url}/api/v1/repos/#{repo}/actions/workflows/#{workflow}/dispatches")
        body = {
          ref: payload.fetch(:ref),
          inputs: payload.fetch(:inputs)
        }.to_json

        http = Net::HTTP.new(url.host, url.port)
        http.use_ssl = url.scheme == "https"
        request = Net::HTTP::Post.new(url.request_uri,
                                      "Authorization" => "token #{@token}",
                                      "Content-Type" => "application/json",
                                      "Accept" => "application/json")
        request.body = body

        response = http.request(request)
        if response.code.to_i.between?(200, 299)
          { ok: true, dispatch_id: response.headers["x-gitea-action-run-id"] || "gitea-#{SecureRandom.hex(8)}" }
        else
          { ok: false, error: "Gitea returned #{response.code}: #{response.body[0..200]}" }
        end
      rescue StandardError => e
        { ok: false, error: "Gitea HTTP failed: #{e.message}" }
      end
    end
  end
end
