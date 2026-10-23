# frozen_string_literal: true

# "Is this pid still running?" for specs that kill a process GROUP and then
# look at a grandchild.
#
# `Process.kill(0, pid)` raises ESRCH only once the pid has been REAPED. A
# killed grandchild is orphaned and reparented to PID 1, which has to wait()
# on it. On a CI runner container PID 1 is `/bin/sleep` (act_runner's job
# container entrypoint) and never reaps, so the killed grandchild stays a
# zombie ("Z") for the life of the container and kill(0) keeps succeeding --
# the spec then reports a process that is already dead as "still alive".
# A zombie has been killed: its state is Z, it runs nothing and holds no
# resources but its pid slot. A process that SURVIVED the kill is in R/S/D,
# so this still fails the spec for the real defect (the group kill missing).
module ProcessLivenessHelpers
  # true once the pid is gone or is only a zombie awaiting its reaper
  def process_dead?(pid)
    Process.kill(0, pid)
    process_state(pid) == "Z"
  rescue Errno::ESRCH
    true
  end

  # one-letter state from /proc/<pid>/stat; nil where /proc is unavailable
  # (then the caller's kill(0) answer stands, as before)
  def process_state(pid)
    stat = File.read("/proc/#{pid}/stat")
    # field 3, after the parenthesised comm (which may itself contain spaces)
    stat[/\)\s+(\S)/, 1]
  rescue Errno::ENOENT, Errno::ESRCH
    nil
  end
end
