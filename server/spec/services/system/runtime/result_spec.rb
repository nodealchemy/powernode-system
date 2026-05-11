# frozen_string_literal: true

require 'rails_helper'

RSpec.describe System::Runtime::Result do
  describe '.ok' do
    it 'returns a successful result with default empty data' do
      result = described_class.ok
      expect(result.success?).to be true
      expect(result.failure?).to be false
      expect(result.data).to eq({})
      expect(result.error).to be_nil
      expect(result.events).to eq([])
    end

    it 'accepts custom data and events' do
      result = described_class.ok(data: { id: 'abc' }, events: [ { type: 'started' } ])
      expect(result.data).to eq(id: 'abc')
      expect(result.events).to eq([ { type: 'started' } ])
    end
  end

  describe '.err' do
    it 'returns a failure result with the error string' do
      result = described_class.err(error: 'something broke')
      expect(result.success?).to be false
      expect(result.failure?).to be true
      expect(result.error).to eq('something broke')
    end

    it 'accepts data alongside the error for diagnostic context' do
      result = described_class.err(error: 'no creds', data: { provider: 'aws' })
      expect(result.data).to eq(provider: 'aws')
    end
  end

  describe '#to_h' do
    it 'compacts nil values from the hash representation' do
      result = described_class.ok(data: { foo: 'bar' })
      hash = result.to_h
      expect(hash).to include(success: true, data: { foo: 'bar' }, events: [])
      expect(hash).not_to have_key(:error)
    end
  end

  describe 'predicate symmetry' do
    it 'has success? and failure? mutually exclusive' do
      ok = described_class.ok
      err = described_class.err(error: 'x')
      expect(ok.success?).to be true
      expect(ok.failure?).to be false
      expect(err.success?).to be false
      expect(err.failure?).to be true
    end
  end

end
