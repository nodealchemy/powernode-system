# frozen_string_literal: true

module System
  # Pure-logic service that compiles a NodeModule's deployment-context-aware
  # rsync filter rules + package list into the strings the M1 CI composer
  # stage feeds to `rsync --filter=` and `apt-get install`.
  #
  # Inputs: a NodeModule + an optional deployment target (Node or NodeInstance
  # whose union mount this module participates in).
  # Outputs: a compiled spec hash:
  #   {
  #     rsync_spec: "- /etc/secret\n+ /etc/desired\n- *\n",
  #     package_spec: "nginx\nlibpcre3\n",
  #     fingerprint: "sha256:<hash of compiled inputs>"  # cache key for CI
  #   }
  #
  # Reference: Golden Eclipse plan — M1 two-stage CI; M0.F (effective_mask + rsync_spec);
  # legacy node_module.rb#rsync_spec (lines 268-271).
  class RsyncSpecCompiler
    Result = Struct.new(:rsync_spec, :package_spec, :fingerprint, keyword_init: true)

    def self.compile(node_module:, target: nil)
      new.compile(node_module: node_module, target: target)
    end

    def compile(node_module:, target: nil)
      rsync = node_module.rsync_spec(target: target)
      packages = decoded_lines(node_module.package_spec)
      package_text = packages.empty? ? "" : "#{packages.join("\n")}\n"

      Result.new(
        rsync_spec: rsync,
        package_spec: package_text,
        fingerprint: ::Digest::SHA256.hexdigest("#{rsync}|#{package_text}")
      )
    end

    private

    def decoded_lines(spec)
      return [] if spec.blank?
      return spec unless spec.is_a?(Array)

      spec.map { |entry| ::Base64.decode64(entry) }
    end
  end
end
