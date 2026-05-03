# frozen_string_literal: true

require 'rails_helper'

RSpec.describe System::WorkerDispatch do
  let(:redis) { instance_double(Redis) }

  before do
    allow(Redis).to receive(:new).and_return(redis)
    allow(redis).to receive(:close)
    allow(redis).to receive(:sadd)
    allow(redis).to receive(:lpush)
  end

  describe '.enqueue' do
    it 'pushes a Sidekiq-format JSON payload to the named queue' do
      jid = described_class.enqueue('FooJob', args: [ 'arg-1', 42 ])

      expect(redis).to have_received(:sadd).with('queues', 'system')
      expect(redis).to have_received(:lpush) do |key, payload|
        expect(key).to eq('queue:system')
        parsed = JSON.parse(payload)
        expect(parsed).to include(
          'class' => 'FooJob',
          'args' => [ 'arg-1', 42 ],
          'queue' => 'system',
          'retry' => false
        )
        expect(parsed['jid']).to match(/\A[0-9a-f]{24}\z/)
        expect(parsed['created_at']).to be_a(Numeric)
        expect(parsed['enqueued_at']).to be_a(Numeric)
      end

      expect(jid).to match(/\A[0-9a-f]{24}\z/)
    end

    it 'wraps a non-array arg in an array' do
      described_class.enqueue('FooJob', args: 'just-one')

      expect(redis).to have_received(:lpush) do |_, payload|
        expect(JSON.parse(payload)['args']).to eq([ 'just-one' ])
      end
    end

    it 'honors a custom queue and retry value' do
      described_class.enqueue('FooJob', args: [], queue: 'critical', retry_count: 3)

      expect(redis).to have_received(:sadd).with('queues', 'critical')
      expect(redis).to have_received(:lpush) do |key, payload|
        expect(key).to eq('queue:critical')
        parsed = JSON.parse(payload)
        expect(parsed['queue']).to eq('critical')
        expect(parsed['retry']).to eq(3)
      end
    end

    it 'closes the Redis connection even if lpush raises' do
      allow(redis).to receive(:lpush).and_raise(Redis::CannotConnectError)

      expect {
        described_class.enqueue('FooJob', args: [])
      }.to raise_error(Redis::CannotConnectError)

      expect(redis).to have_received(:close)
    end
  end

  describe '.enqueue_operation_execution' do
    it 'enqueues SystemExecuteTaskJob with the operation id' do
      described_class.enqueue_operation_execution('op-uuid-123')

      expect(redis).to have_received(:lpush) do |_, payload|
        parsed = JSON.parse(payload)
        expect(parsed['class']).to eq('SystemExecuteTaskJob')
        expect(parsed['args']).to eq([ 'op-uuid-123' ])
      end
    end
  end

  describe '.redis_url' do
    around do |example|
      original = ENV['REDIS_URL']
      example.run
    ensure
      ENV['REDIS_URL'] = original
    end

    it 'returns the REDIS_URL env var when present' do
      ENV['REDIS_URL'] = 'redis://other:6380/9'
      expect(described_class.redis_url).to eq('redis://other:6380/9')
    end

    it 'falls back to redis://localhost:6379/1 when REDIS_URL is unset' do
      ENV.delete('REDIS_URL')
      expect(described_class.redis_url).to eq('redis://localhost:6379/1')
    end
  end
end
