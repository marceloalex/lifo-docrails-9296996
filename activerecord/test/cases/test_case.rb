require 'active_support/test_case'

module ActiveRecord
  # = Active Record Test Case
  #
  # Defines some test assertions to test against SQL queries.
  class TestCase < ActiveSupport::TestCase #:nodoc:
    setup :cleanup_identity_map

    def setup
      cleanup_identity_map
    end

    def teardown
      ActiveRecord::SQLCounter.log.clear
    end

    def cleanup_identity_map
      ActiveRecord::IdentityMap.clear
    end

    def assert_date_from_db(expected, actual, message = nil)
      # SybaseAdapter doesn't have a separate column type just for dates,
      # so the time is in the string and incorrectly formatted
      if current_adapter?(:SybaseAdapter)
        assert_equal expected.to_s, actual.to_date.to_s, message
      else
        assert_equal expected.to_s, actual.to_s, message
      end
    end

    def assert_sql(*patterns_to_match)
      ActiveRecord::SQLCounter.log = []
      yield
      ActiveRecord::SQLCounter.log
    ensure
      failed_patterns = []
      patterns_to_match.each do |pattern|
        failed_patterns << pattern unless ActiveRecord::SQLCounter.log.any?{ |sql| pattern === sql }
      end
      assert failed_patterns.empty?, "Query pattern(s) #{failed_patterns.map{ |p| p.inspect }.join(', ')} not found.#{ActiveRecord::SQLCounter.log.size == 0 ? '' : "\nQueries:\n#{ActiveRecord::SQLCounter.log.join("\n")}"}"
    end

    def assert_queries(num = 1)
      ActiveRecord::SQLCounter.log = []
      yield
    ensure
      assert_equal num, ActiveRecord::SQLCounter.log.size, "#{ActiveRecord::SQLCounter.log.size} instead of #{num} queries were executed.#{ActiveRecord::SQLCounter.log.size == 0 ? '' : "\nQueries:\n#{ActiveRecord::SQLCounter.log.join("\n")}"}"
    end

    def assert_no_queries(&block)
      prev_ignored_sql = ActiveRecord::SQLCounter.ignored_sql
      ActiveRecord::SQLCounter.ignored_sql = []
      assert_queries(0, &block)
    ensure
      ActiveRecord::SQLCounter.ignored_sql = prev_ignored_sql
    end

    def sqlite3? connection
      connection.class.name.split('::').last == "SQLite3Adapter"
    end
  end
end
