# frozen_string_literal: true

# IMP-9ce0ed39c557 — five-minute sweep for Ai::DeferredOperations stuck
# `executing` under system.instance.out_of_band_exec past timeout_seconds+
# margin. All real work happens server-side
# (System::OutOfBandExecReaperService, via the worker_api endpoint below) so
# this worker never imports the AI/governance models directly — mirrors
# System::IdentityReaperJob's pattern (core worker) exactly, adapted for this
# extension's own worker/config/sidekiq_system.yml schedule.
#
# NEVER RE-RUNS THE COMMAND. A stuck row means the executor that was running
# it is gone (crashed, redeployed, OOM-killed); replaying an out-of-band
# shell command a second time with no visibility into whether the first one
# completed is a correctness and safety hazard this design refuses to take
# on. The server-side service only fails the row and records that it did.
class OutOfBandExecReaperJob < BaseJob
  sidekiq_options queue: 'system', retry: 3

  def execute
    logger.info '[OutOfBandExecReaperJob] starting stuck-executing sweep'

    response = BackendApiClient.new.post(
      '/api/v1/system/worker_api/out_of_band_exec/reap',
      {}
    )

    if response.is_a?(Hash) && response[:success] == false
      raise BackendApiClient::ApiError, "reap failed: #{response[:error] || 'unknown'}"
    end

    failed_count = extract(response, :failed_count)
    logger.info "[OutOfBandExecReaperJob] sweep complete failed_count=#{failed_count || '?'}"
    response
  end

  private

  def extract(response, key)
    return nil unless response.is_a?(Hash)
    response.dig(:data, key) || response.dig('data', key.to_s)
  end
end
