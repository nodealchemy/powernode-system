# frozen_string_literal: true

namespace :system do
  namespace :service_capabilities do
    desc "READ-ONLY: compare every module service's stored capabilities with its module's stored " \
         "manifest on key presence (System::ServiceCapabilitiesProvenance.drift_report), and list the " \
         "modules left unmarked (legacy inherit mode). Run before promoting an agent that carries the " \
         "per-service capability resolver (IMP-caef5c00d63f). Exits 1 when any row drifts."
    task drift: :environment do
      report = ::System::ServiceCapabilitiesProvenance.drift_report

      puts "system:service_capabilities:drift — #{report[:checked]} service row(s) checked, " \
           "#{report[:marked_module_ids].size} module(s) marked."

      puts "DRIFT (#{report[:drift].size} row(s) disagree with their stored manifest):"
      report[:drift].each do |d|
        puts "  #{d[:module]}/#{d[:service]}: manifest #{d[:manifest]}, stored #{d[:stored].inspect}"
      end

      puts "UNMARKED — legacy declared [] (#{report[:legacy_empty_modules].size} module(s); republish from the swept manifest):"
      report[:legacy_empty_modules].each { |m| puts "  #{m[:module]}: #{m[:services].join(', ')}" }

      puts "UNMARKED — manifest cannot vouch (#{report[:unvouched_modules].size} module(s)):"
      report[:unvouched_modules].each do |m|
        puts "  #{m[:module]}: #{m[:services].map { |s| "#{s[:service]} (#{s[:reason]})" }.join(', ')}"
      end

      exit(1) if report[:drift].any?
    end
  end
end
