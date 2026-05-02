# frozen_string_literal: true

module System
  module Providers
    module LocalQemu
      # Records every invocation; returns scripted ok responses. Tests
      # assert on `runner.invocations` to verify provider behavior without
      # needing a real libvirt daemon.
      class RecorderRunner
        attr_reader :invocations

        def initialize
          @invocations = []
          @canned = {}
        end

        # Test helper: stub a method's return value
        def stub(method_name, response)
          @canned[method_name] = response
        end

        Runner::REQUIRED.each do |meth|
          define_method(meth) do |**args|
            @invocations << { method: meth, args: args }
            @canned[meth] || default_response(meth)
          end
        end

        private

        def default_response(meth)
          case meth
          when :uri_check!
            { ok: true, uri: "qemu:///system" }
          when :dominfo!
            { ok: true, state: "running", private_ip: "192.168.122.42" }
          when :list_domains!
            { ok: true, domains: [] }
          else
            { ok: true }
          end
        end
      end
    end
  end
end
