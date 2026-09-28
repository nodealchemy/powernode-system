# frozen_string_literal: true

require "open3"
require "timeout"

module System
  # IMP-9ce0ed39c557 — a deadline- and output-capped subprocess runner.
  #
  # Extracted from System::SshExecutionService rather than folded into it:
  # the read/kill loop below has nothing SSH-specific about it (it takes a
  # plain argv), so it is unit-testable against real, harmless local
  # commands (`sleep`, `yes`) instead of faking Open3's streaming semantics
  # or standing up a real SSH server. SshExecutionService#execute_bounded
  # builds the `ssh ...` argv and hands it here.
  #
  # Deliberately separate from System::SshExecutionService#execute (the
  # ~40 existing in-process callers): those stay on Open3.capture3, which
  # never returns until the child exits and never caps output. This class
  # exists ONLY for the opt-in out-of-band-exec path, which runs a
  # caller-named command rather than a platform-authored one and therefore
  # cannot assume it terminates promptly or stays bounded on its own.
  class BoundedCommandRunner
    Result = Struct.new(:stdout, :stderr, :exit_code, :timed_out, :truncated, keyword_init: true) do
      def timed_out?
        !!timed_out
      end

      def truncated?
        !!truncated
      end
    end

    def self.run(argv, timeout_seconds:, max_output_bytes:)
      new.run(argv, timeout_seconds: timeout_seconds, max_output_bytes: max_output_bytes)
    end

    # `argv` is an Array — never a shell string — so the caller-supplied
    # command is a single trusted argv element (e.g. `["ssh", ..., host,
    # command]`), not re-parsed by a shell here. Building THAT argv safely
    # (host/user validation) is the caller's job; this class only bounds
    # whatever it is given.
    def run(argv, timeout_seconds:, max_output_bytes:)
      raise ArgumentError, "timeout_seconds must be positive" unless timeout_seconds.to_f.positive?
      raise ArgumentError, "max_output_bytes must be positive" unless max_output_bytes.to_i.positive?

      @max_output_bytes = max_output_bytes.to_i
      stdout_buf = +""
      stderr_buf = +""
      timed_out = false
      truncated = false
      exit_code = nil

      # pgroup: true (review finding) — puts argv's process in a NEW process
      # group of its own, rather than this Ruby process's group. Without it,
      # #kill! below can only signal the single direct child (e.g. the local
      # `ssh` binary): any LOCAL grandchild it spawns (an askpass helper, a
      # ControlMaster multiplexer) survives a kill of just that one pid. With
      # it, `Process.kill(sig, -pid)` reaches the whole group at once. This
      # bounds what runs on THIS host; the REMOTE side of an ssh invocation
      # is a different process tree entirely and is bounded separately — see
      # SshExecutionService#execute_ssh_command_bounded's `timeout -k` wrap.
      Open3.popen3(*argv, pgroup: true) do |stdin, stdout, stderr, wait_thr|
        stdin.close
        deadline = monotonic_now + timeout_seconds
        open_streams = { stdout => stdout_buf, stderr => stderr_buf }

        until open_streams.empty?
          remaining = deadline - monotonic_now
          if remaining <= 0
            timed_out = true
            kill!(wait_thr.pid)
            break
          end

          ready, = IO.select(open_streams.keys, nil, nil, [ remaining, 0.5 ].min)
          next if ready.nil?

          ready.each { |io| truncated = true if drain!(io, open_streams) }
        end

        # EOF on both streams does NOT mean the process has exited (review
        # finding) — a child that closes/redirects its own stdout and stderr
        # elsewhere and keeps running would otherwise empty open_streams,
        # fall through this whole method with timed_out still false, and
        # leave the unbounded `wait_thr.value` inside #reap below to hang
        # past the deadline this method exists to enforce. So: whenever the
        # read loop above exited WITHOUT already timing out, still wait for
        # real exit — but never longer than what is left of the deadline.
        unless timed_out
          remaining = deadline - monotonic_now
          if remaining <= 0 || !exited_within?(wait_thr, remaining)
            timed_out = true
            kill!(wait_thr.pid)
          end
        end

        # Always called, timeout or not — NOT to avoid a zombie. Open3.popen3
        # builds `wait_thr` internally via `Process.detach`, which reaps the
        # child in its OWN background thread the moment it exits, whether or
        # not anything here ever reads `wait_thr.value` — so skipping this
        # call would never leave a zombie. It is how the exit status is
        # actually READ, not how the process is reaped. exit_code is still
        # reported as nil when timed_out: the caller's contract is "killed"
        # rather than "exited with a code", so the reaped status is
        # discarded on that branch rather than surfaced.
        reaped = reap(wait_thr)
        exit_code = reaped unless timed_out
      end

      Result.new(stdout: stdout_buf, stderr: stderr_buf, exit_code: exit_code,
                 timed_out: timed_out, truncated: truncated)
    end

    private

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # Reads whatever is currently available on `io` into its buffer in
    # open_streams, capping at @max_output_bytes per stream and dropping
    # the stream once the peer closes it. Returns true iff this read had
    # to discard bytes because the cap was already (or newly) reached.
    def drain!(io, open_streams)
      chunk = io.read_nonblock(65_536)
      buf = open_streams[io]
      capacity = @max_output_bytes - buf.bytesize
      if capacity <= 0
        true
      elsif chunk.bytesize > capacity
        buf << chunk.byteslice(0, capacity)
        true
      else
        buf << chunk
        false
      end
    rescue EOFError
      open_streams.delete(io)
      false
    rescue IO::WaitReadable
      false
    end

    # Signals the WHOLE PROCESS GROUP (negative pid), not just the direct
    # child — see the pgroup: true note on Open3.popen3 above. A plain
    # `Process.kill(sig, pid)` here would leave a local grandchild (e.g. a
    # `bash -c 'sleep 30 & wait'` style command, where `sleep` is a child of
    # the killed bash, not of this process) running past the deadline
    # (review finding).
    #
    # Both signals sent unconditionally: the deadline has already passed by
    # the time this is called, so there is no grace period to preserve —
    # TERM gives a well-behaved group one chance to exit on its own signal
    # handler, KILL guarantees it regardless. ESRCH (already exited between
    # the two, or the group leader exited before pgroup setup completed) is
    # the only expected failure from either.
    def kill!(pid)
      Process.kill("TERM", -pid)
    rescue Errno::ESRCH
      nil
    ensure
      begin
        Process.kill("KILL", -pid)
      rescue Errno::ESRCH
        nil
      end
    end

    # Review finding C2-3, corrected. The previous version wrapped this in
    # `Timeout.timeout(REAP_TIMEOUT_SECONDS)`, documented as a bound on how
    # long reaping could take — that bound was never real:
    # `Process.detach`, which `Open3.popen3` uses internally to build
    # `wait_thr`, already reaps the child in its OWN background thread the
    # moment it exits — independent of whether or when this method ever
    # runs. (`Open3.popen3`'s own `ensure` also calls `wait_thr.join`, but
    # only AFTER the block passed to it returns — i.e. AFTER this method has
    # already run — so that `ensure` is not what stands between this call
    # and a zombie either; nothing here needs it to be.) `Timeout.timeout`
    # does not reliably interrupt a blocking `Process#wait`-family call in
    # the first place (confirmed empirically elsewhere in this class's
    # history), but that was never the actual risk: after #kill! SIGKILLs
    # the whole process group, `wait_thr.value` returns PROMPTLY, reading a
    # result the detached thread has already computed or is about to — there
    # is no unbounded wait left to guard against at this call site, only a
    # false sense that one was being bounded.
    def reap(wait_thr)
      wait_thr.value&.exitstatus
    end

    # True iff the process exits on its own within `seconds`. `seconds` must
    # be strictly positive — Ruby's Timeout.timeout treats 0 or nil as "no
    # timeout at all" (it would just wait forever), so the caller guards
    # `remaining <= 0` before ever reaching here.
    def exited_within?(wait_thr, seconds)
      Timeout.timeout(seconds) { wait_thr.join }
      true
    rescue Timeout::Error
      false
    end
  end
end
