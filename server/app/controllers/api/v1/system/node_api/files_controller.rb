# frozen_string_literal: true

module Api
  module V1
    module System
      module NodeApi
        # File download endpoint for node instances
        # Provides access to module data files and other resources
        class FilesController < BaseController
          # GET /api/v1/system/node_api/files/modules/:id(/:filename)
          # Streams the module blob to the on-node agent. Two pathways:
          #
          # 1. M1 OCI artifact present — proxy the composefs layer via
          #    System::OciBlobProxyService. The first request per (digest)
          #    pulls from the upstream registry into a local cache; all
          #    subsequent requests serve from disk. Response Content-Type
          #    is the composefs media type and the X-Module-Digest header
          #    carries the sha256 for the agent's verifier.
          #
          # 2. Legacy operator-uploaded data file — preserved for back-compat
          #    with the pre-M1 publish flow. Matches when no OCI artifact
          #    exists AND the requested filename matches data_file_name.
          #
          # The 404 path differs by failure mode so operators can tell at a
          # glance whether the issue is "no published artifact" vs "filename
          # mismatch on a legacy data_file" vs "no module visible to this node".
          #
          # Route param signature note: the route is
          # `get "files/modules/:id(/:filename)"` — the controller reads
          # params[:id] (NOT params[:module_id]; earlier code looked up the
          # wrong key and always 404'd).
          def module_file
            module_id = params[:id] || params[:module_id]
            node_module = node_modules.find(module_id)
            filename = params[:filename]

            artifact = preferred_artifact(node_module)
            if artifact
              return stream_oci_artifact(artifact, node_module)
            end

            if filename.blank? || node_module.data_file_name != filename
              return render_not_found("File")
            end

            # Legacy data-file pathway. Streaming the actual bytes is still
            # operator-storage-dependent (S3/local FS); for now we expose
            # the metadata + checksum so the agent can verify what it
            # downloads out-of-band. This branch never fires for M1 modules.
            render_success(
              file: {
                id: node_module.id,
                name: filename,
                size: node_module.data_file_size,
                checksum: node_module.data_checksum,
                content_type: detect_content_type(filename)
              },
              message: "Legacy data_file metadata only — OCI artifact path is the supported transport"
            )
          rescue ActiveRecord::RecordNotFound
            render_record_not_found("NodeModule")
          rescue ::System::OciBlobProxyService::PullError => e
            ::Rails.logger.error("[FilesController#module_file] OCI proxy failed for #{module_id}: #{e.message}")
            render_error("OCI blob fetch failed: #{e.message}", :bad_gateway)
          end

          # GET /api/v1/system/node_api/files/scripts/:script_id
          # Download script file
          def script_file
            script = node_scripts.find(params[:script_id])

            render_success(
              file: {
                id: script.id,
                name: "#{script.name}.#{script_extension(script.interpreter)}",
                content: script.content,
                checksum: Digest::SHA256.hexdigest(script.content || ""),
                content_type: "text/plain"
              }
            )
          rescue ActiveRecord::RecordNotFound
            render_record_not_found("Script")
          end

          private

          # Picks the best ModuleArtifact for the calling node's
          # architecture. Mirrors the same-named helper in
          # ModulesController so the two endpoints agree on which
          # artifact represents "this module" — drift between them
          # would let the agent pull a different blob than what the
          # download endpoint advertises.
          def preferred_artifact(mod)
            version = mod.current_version
            return nil unless version

            artifacts = version.module_artifacts
            return nil if artifacts.blank?

            arch = current_instance&.architecture.presence
            (arch && artifacts.find { |a| a.architecture == arch }) || artifacts.first
          end

          # Streams the composefs blob through OciBlobProxyService.
          # send_file uses Rails's chunked transfer encoding so the
          # full blob never lives in Rails memory. X-Module-Digest +
          # ETag headers let the agent's verifier short-circuit on
          # already-cached blobs without re-hashing.
          def stream_oci_artifact(artifact, node_module)
            path = ::System::OciBlobProxyService.new(artifact).fetch_blob!
            response.headers["X-Module-Digest"] = artifact.oci_digest.to_s
            response.headers["X-Module-OCI-Ref"] = artifact.oci_ref.to_s
            response.headers["X-Module-Fsverity-Root"] = artifact.fsverity_root_hash.to_s if artifact.fsverity_root_hash.present?
            response.headers["ETag"] = %("#{artifact.oci_digest}")
            send_file(
              path,
              type: ::System::ModuleArtifact::DEFAULT_MEDIA_TYPE,
              disposition: "attachment",
              filename: "#{node_module.name}.cfs",
              stream: true,
              buffer_size: 65_536
            )
          end

          def node_modules
            module_ids = ::System::NodeModuleAssignment
                         .where(node_id: current_node.id, enabled: true)
                         .pluck(:node_module_id)

            ::System::NodeModule.where(id: module_ids)
          end

          def node_scripts
            template = current_node.node_template

            if template&.respond_to?(:scripts)
              template.scripts
            else
              ::System::NodeScript.where(account_id: current_account.id)
            end
          end

          def detect_content_type(filename)
            extension = File.extname(filename).downcase

            case extension
            when ".tar", ".tar.gz", ".tgz"
              "application/x-tar"
            when ".gz"
              "application/gzip"
            when ".zip"
              "application/zip"
            when ".json"
              "application/json"
            when ".yaml", ".yml"
              "application/x-yaml"
            when ".sh"
              "application/x-sh"
            when ".rb"
              "application/x-ruby"
            when ".py"
              "application/x-python"
            else
              "application/octet-stream"
            end
          end

          def script_extension(interpreter)
            case interpreter
            when /bash|sh/i
              "sh"
            when /ruby/i
              "rb"
            when /python/i
              "py"
            when /perl/i
              "pl"
            else
              "sh"
            end
          end
        end
      end
    end
  end
end
