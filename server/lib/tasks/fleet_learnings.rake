# frozen_string_literal: true

namespace :system do
  namespace :fleet do
    desc "F3-12 one-time cleanup: delete zero-information fleet learnings and collapse duplicates onto the oldest row"
    task consolidate_learnings: :environment do
      result = System::Fleet::LearningExtractor.consolidate_legacy_rows!
      puts "Fleet learning consolidation: deleted #{result[:deleted_zero_info]} zero-information rows, " \
           "collapsed #{result[:deleted_duplicates]} duplicates"
    end
  end
end
