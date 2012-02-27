module ActiveRecord
  ###
  # This class encapsulates a Result returned from calling +exec_query+ on any
  # database connection adapter. For example:
  #
  #   x = ActiveRecord::Base.connection.exec_query('SELECT * FROM foo')
  #   x # => #<ActiveRecord::Result:0xdeadbeef>
  class Result
    include Enumerable

    attr_reader :columns, :rows

    def initialize(columns, rows)
      @columns   = columns
      @rows      = rows
      @hash_rows = nil
    end

    def each
      hash_rows.each { |row| yield row }
    end

    def to_hash
      hash_rows
    end

    alias :map! :map
    alias :collect! :map

    def empty?
      rows.empty?
    end

    def to_ary
      hash_rows
    end

    def [](idx)
      hash_rows[idx]
    end

    def last
      hash_rows.last
    end

    def initialize_copy(other)
      @columns   = columns.dup
      @rows      = rows.dup
      @hash_rows = nil
    end

    private
    def hash_rows
      @hash_rows ||= @rows.map { |row|
        Hash[@columns.zip(row)]
      }
    end
  end
end
