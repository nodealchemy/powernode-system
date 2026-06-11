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
            artifact = node_module.current_version&.artifact
            return render_not_found("ModuleArtifact") unless artifact

            stream_erofs_blob(node_module, artifact)
          rescue ActiveRecord::RecordNotFound
            render_record_not_found("NodeModule")
          rescue ::System::OciBlobProxyService::PullError => e
            ::Rails.logger.error("[FilesController#module_file] OCI proxy failed for #{module_id}: #{e.message}")
            render_error("OCI blob fetch failed: #{e.message}", :bad_gateway)
          end

          # GET /api/v1/system/node_api/files/scripts/:id
          # Download script file. F5-03: the route param is :id but this read
          # params[:script_id] (find(nil) → always 404 — the same wrong-key
          # drift module_file's note warns about), and it served
          # script.content / script.interpreter — attributes NodeScript does
          # not have. The body column is `data`; the interpreter is inferred
          # from its shebang line for the filename extension.
          def script_file
            script = node_scripts.find(params[:id] || params[:script_id])
            body = script.data.to_s

            render_success(
              file: {
                id: script.id,
                name: "#{script.name}.#{script_extension(body.lines.first)}",
                content: body,
                checksum: Digest::SHA256.hexdigest(body),
                content_type: "text/plain"
              }
            )
          rescue ActiveRecord::RecordNotFound
            render_record_not_found("Script")
          end

          private

          # Streams the erofs blob through OciBlobProxyService.
          # send_file uses Rails's chunked transfer encoding so the
          # full blob never lives in Rails memory. X-Module-Digest +
          # ETag headers let the agent's verifier short-circuit on
          # already-cached blobs without re-hashing.
          def stream_erofs_blob(node_module, artifact)
            # Prefer pull-by-digest when the platform has a recorded
            # oci_digest (the standard case after ingest). Bypasses
            # the manifest fetch + sidesteps the tag-republish race
            # that bit ops2's first dogfood pass — mmdebstrap-built
            # blobs change bytes on every rebuild, so a stored digest
            # can be stale relative to the registry's current
            # /v2/<repo>/manifests/<tag> response. /v2/<repo>/blobs/<digest>
            # is content-addressable; the registry can't return wrong
            # bytes for a given digest.
            path = ::System::OciBlobProxyService.new(
              oci_ref:    artifact["oci_ref"],
              media_type: artifact["media_type"],
              digest:     artifact["oci_digest"],
              size:       artifact["size"],
              node_module: node_module
            ).fetch_blob!
            response.headers["X-Module-Digest"] = artifact["oci_digest"].to_s
            response.headers["X-Module-OCI-Ref"] = artifact["oci_ref"].to_s
            response.headers["X-Module-Fsverity-Root"] = artifact["fsverity_root"].to_s if artifact["fsverity_root"].present?
            response.headers["ETag"] = %("#{artifact["oci_digest"]}")
            send_file(
              path,
              type: artifact["media_type"],
              disposition: "attachment",
              filename: "#{node_module.name}.erofs",
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
