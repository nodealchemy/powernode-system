# frozen_string_literal: true

# RepoSyncService runs git through Open3.popen3 (so it can enforce
# CLONE_TIMEOUT_SEC), while its specs describe each git invocation by stubbing
# Open3.capture3. This routes popen3 through whatever capture3 does at call time
# (the stub when there is one, the real thing otherwise), so those specs keep
# describing invocations the same way.
module GitPopen3Routing
  FakeWait = Struct.new(:status) do
    def join(_timeout = nil) = self
    def value = status
    # The routing stub runs no process: reaching a kill is a spec bug, and a real
    # pid here (0 would signal the rspec process group) must never be signalled.
    def pid = raise("FakeWait has no process to signal; the kill path was reached under the popen3 routing stub")
  end

  def route_popen3_through_capture3!
    allow(Open3).to receive(:popen3) do |*args, **kwargs, &block|
      out, err, status = Open3.capture3(*args, **kwargs)
      block.call(StringIO.new, StringIO.new(out.to_s), StringIO.new(err.to_s), FakeWait.new(status))
    end
  end
end


