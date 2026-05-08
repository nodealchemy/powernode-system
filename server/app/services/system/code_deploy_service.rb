# frozen_string_literal: true

module System
  # M3 self-serve "Run My Code" — clones a Git repo onto a NodeInstance via
  # SSH, detects (or accepts) the runtime, installs dependencies, and writes a
  # systemd unit (`/etc/systemd/system/powernode-app.service`) that runs the
  # operator-supplied (or auto-detected) start command.
  #
  # Used by Slice B's `DeployAppCodeExecutor`: the executor receives the brief
  # fields (repo_url, branch, start_command, optional deploy_key) plus the
  # provisioned NodeInstance and dispatches here to do the actual deploy.
  #
  # Returns a uniform envelope:
  #
  #   { success: bool, commit_sha: <sha or nil>, public_url: <url or nil>, error: <string or nil> }
  #
  # SSH transport is delegated to `System::SshExecutionService`. That service
  # owns key resolution + Open3-based execution + the SYSTEM_SSH_ENABLED=false
  # mock-mode used by tests, so this class stays focused on the deploy
  # workflow. Specs stub `System::SshExecutionService.execute` directly
  # rather than driving Open3.
  #
  # AI-Driven Provisioning M3 — slice A (Run My Code).
  class CodeDeployService
    APP_DIR          = "/opt/app"
    UNIT_PATH        = "/etc/systemd/system/powernode-app.service"
    SERVICE_NAME     = "powernode-app"
    DEPLOY_KEY_PATH  = "/root/.ssh/id_ed25519"
    KNOWN_HOSTS_PATH = "/root/.ssh/known_hosts"
    SUPPORTED_RUNTIMES = %w[nodejs python].freeze

    # Runtime-detection probes, in priority order. Each entry is
    # [runtime_name, sentinel_filename]. The first sentinel that exists in
    # the cloned repo wins.
    RUNTIME_PROBES = [
      [ "nodejs", "package.json" ],
      [ "python", "requirements.txt" ],
      [ "python", "pyproject.toml" ]
    ].freeze

    def self.call(node_instance:, repo_url:, branch: "main", start_command: nil, deploy_key: nil)
      new(
        node_instance: node_instance,
        repo_url: repo_url,
        branch: branch,
        start_command: start_command,
        deploy_key: deploy_key
      ).call
    end

    # Compensating action for `.call`: stops + disables the powernode-app
    # systemd unit on the instance, removes the unit file, and clears
    # `/opt/app`. Used by `DeployAppCodeExecutor#rollback_deploy_app_code`
    # (Slice B) when a deploy step needs to be undone.
    #
    # Best-effort: each remote command is allowed to fail (the unit may not
    # exist yet, the dir may already be empty) — we only fail the tear_down
    # when the cleanup script as a whole errors out at the SSH transport
    # layer. Returns `{ success:, error: }`.
    def self.tear_down(node_instance:)
      # Validate first so the ArgumentError surfaces to the caller — the
      # SSH-failure rescue below should NOT swallow programmer bugs.
      raise ArgumentError, "node_instance required" unless node_instance

      run_tear_down(node_instance: node_instance)
    end

    # Private worker for `.tear_down`. Wraps the SSH transport in a rescue
    # so transient/network failures land as `{ success: false, error: }`
    # rather than raising — the rollback caller (Slice B's executor)
    # collects errors instead of unwinding.
    def self.run_tear_down(node_instance:)
      script = <<~SCRIPT
        systemctl stop #{SERVICE_NAME} 2>/dev/null || true
        systemctl disable #{SERVICE_NAME} 2>/dev/null || true
        rm -f #{UNIT_PATH}
        systemctl daemon-reload 2>/dev/null || true
        rm -rf #{APP_DIR}
      SCRIPT

      result = ::System::SshExecutionService.execute(
        instance: node_instance,
        command: script,
        sudo: true
      )

      ok = result.respond_to?(:success?) ? result.success? : (result.is_a?(Hash) && result[:exit_code] == 0)
      if ok
        { success: true, error: nil }
      else
        err = result.respond_to?(:error) ? result.error.to_s : "tear_down ssh failed"
        ::Rails.logger.warn("[CodeDeployService] tear_down failed for instance=#{node_instance.respond_to?(:name) ? node_instance.name : node_instance.id}: #{err}")
        { success: false, error: err }
      end
    rescue StandardError => e
      ::Rails.logger.error("[CodeDeployService] tear_down raised: #{e.class}: #{e.message}")
      { success: false, error: e.message }
    end
    private_class_method :run_tear_down

    def initialize(node_instance:, repo_url:, branch: "main", start_command: nil, deploy_key: nil)
      @node_instance = node_instance
      @repo_url      = repo_url
      @branch        = branch.presence || "main"
      @start_command = start_command.presence
      @deploy_key    = deploy_key.presence
    end

    def call
      validate!

      install_deploy_key! if @deploy_key
      ensure_app_dir!
      clone_repo!
      commit_sha = git_rev_parse

      runtime, resolved_start = resolve_runtime_and_start_command!
      install_dependencies!(runtime)
      write_systemd_unit!(resolved_start)
      enable_service!

      {
        success: true,
        commit_sha: commit_sha,
        public_url: derive_public_url
      }
    rescue StandardError => e
      Rails.logger.error("[CodeDeployService] Deploy failed for instance=#{@node_instance&.name}: #{e.message}")
      { success: false, error: e.message }
    end

    private

    def validate!
      raise ArgumentError, "node_instance required" unless @node_instance
      raise ArgumentError, "repo_url required"      if @repo_url.blank?
    end

    # Drops the operator-supplied SSH private key on the instance with mode
    # 0600 + adds github.com to known_hosts so `git clone` over SSH succeeds
    # for private repos. Heredoc preserves newlines in the PEM.
    def install_deploy_key!
      script = <<~SCRIPT
        mkdir -p /root/.ssh && chmod 700 /root/.ssh
        cat > #{DEPLOY_KEY_PATH} <<'POWERNODE_DEPLOY_KEY_EOF'
        #{@deploy_key.strip}
        POWERNODE_DEPLOY_KEY_EOF
        chmod 600 #{DEPLOY_KEY_PATH}
        ssh-keyscan -t rsa,ed25519 -H github.com >> #{KNOWN_HOSTS_PATH} 2>/dev/null || true
        chmod 644 #{KNOWN_HOSTS_PATH}
      SCRIPT
      ssh!(script, summary: "install deploy key")
    end

    def ensure_app_dir!
      ssh!("mkdir -p #{APP_DIR}", summary: "ensure app dir")
    end

    # Idempotent on repeated deploys: scrub any prior tree before cloning so
    # re-runs don't fail on existing .git.
    def clone_repo!
      ssh!(
        "rm -rf #{APP_DIR}/.git #{APP_DIR}/* 2>/dev/null || true",
        summary: "clean app dir"
      )
      ssh!(
        "git clone --depth 1 --branch #{shell_escape(@branch)} #{shell_escape(@repo_url)} #{APP_DIR}",
        summary: "git clone"
      )
    end

    def git_rev_parse
      data = ssh!("cd #{APP_DIR} && git rev-parse HEAD", summary: "git rev-parse")
      stdout = data.is_a?(Hash) ? data[:stdout].to_s : data.to_s
      stdout.strip.presence
    end

    # Returns [runtime_name, resolved_start_command]. If the operator supplied
    # an explicit start_command, uses it verbatim (still returns the runtime
    # tag for downstream dependency installation). Otherwise auto-detects
    # both via filesystem probes over SSH.
    def resolve_runtime_and_start_command!
      runtime = detect_runtime!
      return [ runtime, @start_command ] if @start_command

      start = case runtime
              when "nodejs" then "/usr/bin/npm start"
              when "python" then detect_python_start!
              else
                raise "Cannot auto-detect start command for runtime=#{runtime}"
              end

      [ runtime, start ]
    end

    def detect_runtime!
      RUNTIME_PROBES.each do |runtime, sentinel|
        return runtime if remote_file_exists?("#{APP_DIR}/#{sentinel}")
      end
      raise "Cannot detect runtime for #{@repo_url} — no package.json/requirements.txt/pyproject.toml at repo root"
    end

    def detect_python_start!
      return "python3 app.py"  if remote_file_exists?("#{APP_DIR}/app.py")
      return "python3 main.py" if remote_file_exists?("#{APP_DIR}/main.py")
      raise "Cannot auto-detect Python entrypoint (no app.py/main.py) — supply start_command explicitly"
    end

    def install_dependencies!(runtime)
      case runtime
      when "nodejs"
        ssh!(
          "cd #{APP_DIR} && /usr/bin/npm install --omit=dev",
          summary: "npm install"
        )
      when "python"
        ssh!(
          "cd #{APP_DIR} && if [ -f requirements.txt ]; then python3 -m pip install -r requirements.txt; fi",
          summary: "pip install"
        )
      end
    end

    def write_systemd_unit!(start_command)
      unit = <<~UNIT
        [Unit]
        Description=Powernode operator app
        After=network-online.target
        Wants=network-online.target

        [Service]
        Type=simple
        WorkingDirectory=#{APP_DIR}
        ExecStart=#{start_command}
        Restart=on-failure
        RestartSec=5

        [Install]
        WantedBy=multi-user.target
      UNIT

      script = "cat > #{UNIT_PATH} <<'POWERNODE_APP_UNIT_EOF'\n#{unit}POWERNODE_APP_UNIT_EOF\n"
      ssh!(script, summary: "write systemd unit")
    end

    def enable_service!
      ssh!(
        "systemctl daemon-reload && systemctl enable --now #{SERVICE_NAME}",
        summary: "enable systemd unit"
      )
    end

    # ── SSH boundary ─────────────────────────────────────────────────────
    #
    # Every call goes through `System::SshExecutionService.execute` so we
    # inherit its key/host resolution + the SYSTEM_SSH_ENABLED=false mock
    # path used in tests. Returns Runtime::Result objects.

    def remote_file_exists?(path)
      result = ::System::SshExecutionService.execute(
        instance: @node_instance,
        command: "test -f #{shell_escape(path)}",
        sudo: true
      )
      success?(result)
    end

    def ssh!(command, summary:)
      result = ::System::SshExecutionService.execute(
        instance: @node_instance,
        command: command,
        sudo: true
      )
      unless success?(result)
        raise "SSH command failed: #{summary} — #{result_error(result)}"
      end
      result_data(result)
    end

    def success?(result)
      return result.success? if result.respond_to?(:success?)
      return result[:exit_code] == 0 if result.is_a?(Hash) && result.key?(:exit_code)
      false
    end

    def result_error(result)
      return result.error.to_s if result.respond_to?(:error) && result.error.present?
      return result[:error].to_s if result.is_a?(Hash) && result[:error].present?
      result.respond_to?(:data) ? result.data.to_s : result.to_s
    end

    def result_data(result)
      return result.data || {} if result.respond_to?(:data)
      result.is_a?(Hash) ? result : {}
    end

    # POSIX single-quote escaping. The result is wrapped in single quotes;
    # any single quote in the input is closed, escaped, and re-opened.
    def shell_escape(value)
      "'#{value.to_s.gsub("'") { "'\\''" }}'"
    end

    def derive_public_url
      ip = @node_instance.respond_to?(:public_ip_address) ? @node_instance.public_ip_address : nil
      return nil if ip.blank?
      "http://#{ip}"
    end
  end
end
