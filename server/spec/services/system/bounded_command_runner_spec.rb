# frozen_string_literal: true

require "rails_helper"
require "tempfile"

# IMP-9ce0ed39c557 — exercised against REAL local subprocesses (sleep,
# printf, a small bash loop), not a faked Open3, because the behavior under
# test (the deadline kill, the per-stream byte cap) IS the interaction with
# real OS-level I/O and process signaling. A mock of Open3.popen3 would only
# prove this class calls the mock the way it was told to.
RSpec.describe System::BoundedCommandRunner do
  def run(argv, timeout_seconds: 5, max_output_bytes: 65_536)
    described_class.run(argv, timeout_seconds: timeout_seconds, max_output_bytes: max_output_bytes)
  end

  # Polls rather than a fixed sleep: the kill has already been sent by the
  # time #run returns, so this only needs to wait out the OS's own signal
  # delivery/process-teardown latency, which is normally sub-millisecond.
  def wait_until_gone(pid, timeout:)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      begin
        Process.kill(0, pid)
      rescue Errno::ESRCH
        return true
      end
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.05
    end
  end

  describe "the ordinary case" do
    it "returns stdout, stderr and the real exit code with no timeout or truncation" do
      result = run([ "bash", "-c", "printf out; printf err 1>&2; exit 3" ])

      expect(result.stdout).to eq("out")
      expect(result.stderr).to eq("err")
      expect(result.exit_code).to eq(3)
      expect(result.timed_out?).to be false
      expect(result.truncated?).to be false
    end
  end

  describe "the deadline" do
    it "kills a command that outlives timeout_seconds and reports timed_out with no exit_code" do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = run([ "bash", "-c", "sleep 30" ], timeout_seconds: 1)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(result.timed_out?).to be true
      expect(result.exit_code).to be_nil
      # Killed near the 1s deadline, not left to run anywhere near the full
      # 30s sleep — bounds this as a real kill, not a lucky natural exit.
      expect(elapsed).to be < 10
    end

    # Review finding: the previous version of this example asserted only
    # timed_out? — a claim about #run's REPORTED outcome, not about the OS
    # process table, so it could not fail even if the process were left as
    # a zombie. This has the child report its own real pid (via $$, written
    # to a tempfile from inside the shell) and checks that pid is GONE
    # afterward — kill(pid, 0) raises ESRCH once a process has genuinely
    # exited AND been reaped (a zombie still answers it successfully).
    # Review finding C2-3, retitled: this proves the KILL is real (the
    # process is actually gone after #run returns), not something unique to
    # this class's own reaping — Open3.popen3's block form already joins the
    # child in its own ensure before #run ever returns, independent of
    # whatever #reap does, so it cannot distinguish "we reaped it" from
    # "Open3 always would have". What WOULD fail this: #kill! not actually
    # signaling the right pid/group, in which case the process would still be
    # alive (and this Process.kill(0, pid) would NOT raise).
    it "actually kills the process rather than leaving it running past the deadline" do
      pid_file = Tempfile.new("oob_pid_check")
      path = pid_file.path
      pid_file.close

      run([ "bash", "-c", "echo $$ > #{path}; sleep 30" ], timeout_seconds: 1)

      pid = File.read(path).strip.to_i
      expect(pid).to be_positive
      expect { Process.kill(0, pid) }.to raise_error(Errno::ESRCH)
    ensure
      File.delete(path) if path && File.exist?(path)
    end

    # Review finding — the process GROUP, not just the direct child, must
    # die: without pgroup: true + a group-wide signal, a local grandchild
    # (here, `sleep 30` backgrounded by the killed bash) is orphaned and
    # keeps running past the deadline.
    it "kills the whole process group, including a backgrounded local grandchild" do
      pid_file = Tempfile.new("oob_grandchild_pid")
      path = pid_file.path
      pid_file.close

      run([ "bash", "-c", "sleep 30 & echo $! > #{path}; wait" ], timeout_seconds: 1)

      grandchild_pid = File.read(path).strip.to_i
      expect(grandchild_pid).to be_positive

      gone = wait_until_gone(grandchild_pid, timeout: 5)
      expect(gone).to be(true), "grandchild pid #{grandchild_pid} was still alive after the deadline"
    ensure
      File.delete(path) if path && File.exist?(path)
    end

    # Review finding: EOF on stdout/stderr is not "the process exited". A
    # child that closes both streams and keeps running would previously
    # empty open_streams, fall out of the read loop with timed_out still
    # false, and leave the unbounded wait_thr.value inside #reap to hang —
    # so #run itself would eventually return past its own timeout_seconds,
    # having never called #kill! at all.
    it "still enforces the deadline when the child closes both streams but keeps running" do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = run([ "bash", "-c", "exec 1>&-; exec 2>&-; sleep 30" ], timeout_seconds: 1)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(result.timed_out?).to be true
      expect(elapsed).to be < 10
    end

    it "still captures whatever the command wrote before the kill" do
      result = run(
        [ "bash", "-c", "printf partial; sleep 30" ],
        timeout_seconds: 1
      )

      expect(result.stdout).to eq("partial")
      expect(result.timed_out?).to be true
    end
  end

  describe "the per-stream output cap" do
    it "truncates stdout at max_output_bytes and marks truncated" do
      result = run(
        [ "bash", "-c", "printf 'x%.0s' $(seq 1 5000)" ],
        max_output_bytes: 100
      )

      expect(result.stdout.bytesize).to eq(100)
      expect(result.truncated?).to be true
      expect(result.timed_out?).to be false
      expect(result.exit_code).to eq(0)
    end

    it "caps stdout and stderr independently" do
      result = run(
        [ "bash", "-c", "printf 'o%.0s' $(seq 1 5000); printf 'e%.0s' $(seq 1 5000) 1>&2" ],
        max_output_bytes: 50
      )

      expect(result.stdout.bytesize).to eq(50)
      expect(result.stderr.bytesize).to eq(50)
      expect(result.stdout).to eq("o" * 50)
      expect(result.stderr).to eq("e" * 50)
      expect(result.truncated?).to be true
    end

    it "does not mark truncated when output lands exactly at or under the cap" do
      result = run([ "bash", "-c", "printf '%s' 'exactly10!'" ], max_output_bytes: 10)

      expect(result.stdout).to eq("exactly10!")
      expect(result.truncated?).to be false
    end
  end

  describe "input validation" do
    it "refuses a non-positive timeout_seconds" do
      expect { run([ "true" ], timeout_seconds: 0) }.to raise_error(ArgumentError, /timeout_seconds/)
    end

    it "refuses a non-positive max_output_bytes" do
      expect { run([ "true" ], max_output_bytes: 0) }.to raise_error(ArgumentError, /max_output_bytes/)
    end
  end
end
