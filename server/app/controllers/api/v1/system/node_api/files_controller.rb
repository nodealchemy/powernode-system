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

            # Format dispatch — agent passes ?format=composefs or
            # ?format=squashfs based on its detected kernel capability.
            # When unspecified, fall through to the node-caps-based
            # picker so legacy clients (no format param) still get
            # something mountable.
            format = params[:format].presence
            if format.nil?
              format, _ = pick_format_for_current_node(node_module)
            end
            unless ::System::NodeModuleVersion::SUPPORTED_ARTIFACT_FORMATS.include?(format)
              return render_error("unknown or unavailable format: #{format.inspect}", :bad_request)
            end

            format_artifact = node_module.current_version&.artifact_for(format)
            return render_not_found("ModuleArtifact[#{format}]") unless format_artifact

            stream_format_blob(node_module, format, format_artifact)
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

          # Picks the [format, artifact] pair for the calling node's
          # capabilities. Mirrors ModulesController#pick_artifact_for_node
          # so the two endpoints agree on which format represents "this
          # module" — drift between them would let the agent pull a
          # blob in a different format than the manifest response
          # advertised. Both formats are mandatory on every published
          # module, so neither return value is nil for a publishable
          # version.
          def pick_format_for_current_node(mod)
            version = mod.current_version
            return [nil, nil] unless version
            version.pick_format_for(current_instance&.capabilities || {})
          end

          # Streams the format-specific blob through OciBlobProxyService.
          # send_file uses Rails's chunked transfer encoding so the full
          # blob never lives in Rails memory. X-Module-Digest +
          # X-Module-Format + ETag headers let the agent's verifier
          # short-circuit on already-cached blobs without re-hashing
          # and confirm which format actually streamed.
          def stream_format_blob(node_module, format, format_artifact)
            path = ::System::OciBlobProxyService.from_format(
              node_module: node_module,
              format: format,
              format_artifact: format_artifact
            ).fetch_blob!
            response.headers["X-Module-Digest"] = format_artifact["oci_digest"].to_s
            response.headers["X-Module-OCI-Ref"] = format_artifact["oci_ref"].to_s
            response.headers["X-Module-Format"] = format
            response.headers["X-Module-Fsverity-Root"] = format_artifact["fsverity_root"].to_s if format_artifact["fsverity_root"].present?
            response.headers["ETag"] = %("#{format_artifact["oci_digest"]}")
            extension = format == "squashfs" ? "sqfs" : "cfs"
            send_file(
              path,
              type: format_artifact["media_type"],
              disposition: "attachment",
              filename: "#{node_module.name}.#{extension}",
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
