require "cases/helper"

module ActiveRecord
  module ConnectionAdapters
    class ConnectionPoolTest < ActiveRecord::TestCase
      def setup
        super

        # Keep a duplicate pool so we do not bother others
        @pool = ConnectionPool.new ActiveRecord::Base.connection_pool.spec

        if in_memory_db?
          # Separate connections to an in-memory database create an entirely new database,
          # with an empty schema etc, so we just stub out this schema on the fly.
          @pool.with_connection do |connection|
            connection.create_table :posts do |t|
              t.integer :cololumn
            end
          end
        end
      end

      def teardown
        super
        @pool.disconnect!
      end

      def test_full_pool_exception
        assert_raises(PoolFullError) do
          (@pool.size + 1).times do
            @pool.checkout
          end
        end
      end

      def test_reap_and_active
        @pool.checkout
        @pool.checkout
        @pool.checkout
        @pool.timeout = 0

        connections = @pool.connections.dup

        @pool.reap

        assert_equal connections.length, @pool.connections.length
      end

      def test_reap_inactive
        @pool.checkout
        @pool.checkout
        @pool.checkout
        @pool.timeout = 0

        connections = @pool.connections.dup
        connections.each do |conn|
          conn.extend(Module.new { def active?; false; end; })
        end

        @pool.reap

        assert_equal 0, @pool.connections.length
      ensure
        connections.each(&:close)
      end

      def test_remove_connection
        conn = @pool.checkout
        assert conn.in_use?

        length = @pool.connections.length
        @pool.remove conn
        assert conn.in_use?
        assert_equal(length - 1, @pool.connections.length)
      ensure
        conn.close
      end

      def test_remove_connection_for_thread
        conn = @pool.connection
        @pool.remove conn
        assert_not_equal(conn, @pool.connection)
      ensure
        conn.close if conn
      end

      def test_active_connection?
        assert !@pool.active_connection?
        assert @pool.connection
        assert @pool.active_connection?
        @pool.release_connection
        assert !@pool.active_connection?
      end

      def test_checkout_behaviour
        pool = ConnectionPool.new ActiveRecord::Base.connection_pool.spec
        connection = pool.connection
        assert_not_nil connection
        threads = []
        4.times do |i|
          threads << Thread.new(i) do |pool_count|
            connection = pool.connection
            assert_not_nil connection
            connection.close
          end
        end

        threads.each(&:join)

        Thread.new do
          assert pool.connection
          pool.connection.close
        end.join
      end

      def test_automatic_reconnect=
        pool = ConnectionPool.new ActiveRecord::Base.connection_pool.spec
        assert pool.automatic_reconnect
        assert pool.connection

        pool.disconnect!
        assert pool.connection

        pool.disconnect!
        pool.automatic_reconnect = false

        assert_raises(ConnectionNotEstablished) do
          pool.connection
        end

        assert_raises(ConnectionNotEstablished) do
          pool.with_connection
        end
      end

      def test_pool_sets_connection_visitor
        assert @pool.connection.visitor.is_a?(Arel::Visitors::ToSql)
      end
    end
  end
end
