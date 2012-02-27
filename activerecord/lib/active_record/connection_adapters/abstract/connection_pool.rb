require 'thread'
require 'monitor'
require 'set'
require 'active_support/core_ext/module/deprecation'

module ActiveRecord
  # Raised when a connection could not be obtained within the connection
  # acquisition timeout period.
  class ConnectionTimeoutError < ConnectionNotEstablished
  end

  # Raised when a connection pool is full and another connection is requested
  class PoolFullError < ConnectionNotEstablished
    def initialize size, timeout
      super("Connection pool of size #{size} and timeout #{timeout}s is full")
    end
  end

  module ConnectionAdapters
    # Connection pool base class for managing Active Record database
    # connections.
    #
    # == Introduction
    #
    # A connection pool synchronizes thread access to a limited number of
    # database connections. The basic idea is that each thread checks out a
    # database connection from the pool, uses that connection, and checks the
    # connection back in. ConnectionPool is completely thread-safe, and will
    # ensure that a connection cannot be used by two threads at the same time,
    # as long as ConnectionPool's contract is correctly followed. It will also
    # handle cases in which there are more threads than connections: if all
    # connections have been checked out, and a thread tries to checkout a
    # connection anyway, then ConnectionPool will wait until some other thread
    # has checked in a connection.
    #
    # == Obtaining (checking out) a connection
    #
    # Connections can be obtained and used from a connection pool in several
    # ways:
    #
    # 1. Simply use ActiveRecord::Base.connection as with Active Record 2.1 and
    #    earlier (pre-connection-pooling). Eventually, when you're done with
    #    the connection(s) and wish it to be returned to the pool, you call
    #    ActiveRecord::Base.clear_active_connections!. This will be the
    #    default behavior for Active Record when used in conjunction with
    #    Action Pack's request handling cycle.
    # 2. Manually check out a connection from the pool with
    #    ActiveRecord::Base.connection_pool.checkout. You are responsible for
    #    returning this connection to the pool when finished by calling
    #    ActiveRecord::Base.connection_pool.checkin(connection).
    # 3. Use ActiveRecord::Base.connection_pool.with_connection(&block), which
    #    obtains a connection, yields it as the sole argument to the block,
    #    and returns it to the pool after the block completes.
    #
    # Connections in the pool are actually AbstractAdapter objects (or objects
    # compatible with AbstractAdapter's interface).
    #
    # == Options
    #
    # There are two connection-pooling-related options that you can add to
    # your database connection configuration:
    #
    # * +pool+: number indicating size of connection pool (default 5)
    # * +wait_timeout+: number of seconds to block and wait for a connection
    #   before giving up and raising a timeout error (default 5 seconds).
    class ConnectionPool
      # Every +frequency+ seconds, the reaper will call +reap+ on +pool+.
      # A reaper instantiated with a nil frequency will never reap the
      # connection pool.
      #
      # Configure the frequency by setting "reaping_frequency" in your
      # database yaml file.
      class Reaper
        attr_reader :pool, :frequency

        def initialize(pool, frequency)
          @pool      = pool
          @frequency = frequency
        end

        def run
          return unless frequency
          Thread.new(frequency, pool) { |t, p|
            while true
              sleep t
              p.reap
            end
          }
        end
      end

      include MonitorMixin

      attr_accessor :automatic_reconnect, :timeout
      attr_reader :spec, :connections, :size, :reaper

      # Creates a new ConnectionPool object. +spec+ is a ConnectionSpecification
      # object which describes database connection information (e.g. adapter,
      # host name, username, password, etc), as well as the maximum size for
      # this ConnectionPool.
      #
      # The default ConnectionPool maximum size is 5.
      def initialize(spec)
        super()

        @spec = spec

        # The cache of reserved connections mapped to threads
        @reserved_connections = {}

        @timeout = spec.config[:wait_timeout] || 5
        @reaper  = Reaper.new self, spec.config[:reaping_frequency]
        @reaper.run

        # default max pool size to 5
        @size = (spec.config[:pool] && spec.config[:pool].to_i) || 5

        @connections         = []
        @automatic_reconnect = true
      end

      # Retrieve the connection associated with the current thread, or call
      # #checkout to obtain one if necessary.
      #
      # #connection can be called any number of times; the connection is
      # held in a hash keyed by the thread id.
      def connection
        @reserved_connections[current_connection_id] ||= checkout
      end

      # Check to see if there is an active connection in this connection
      # pool.
      def active_connection?
        active_connections.any?
      end

      # Signal that the thread is finished with the current connection.
      # #release_connection releases the connection-thread association
      # and returns the connection to the pool.
      def release_connection(with_id = current_connection_id)
        conn = @reserved_connections.delete(with_id)
        checkin conn if conn
      end

      # If a connection already exists yield it to the block. If no connection
      # exists checkout a connection, yield it to the block, and checkin the
      # connection when finished.
      def with_connection
        connection_id = current_connection_id
        fresh_connection = true unless active_connection?
        yield connection
      ensure
        release_connection(connection_id) if fresh_connection
      end

      # Returns true if a connection has already been opened.
      def connected?
        synchronize { @connections.any? }
      end

      # Disconnects all connections in the pool, and clears the pool.
      def disconnect!
        synchronize do
          @reserved_connections = {}
          @connections.each do |conn|
            checkin conn
            conn.disconnect!
          end
          @connections = []
        end
      end

      # Clears the cache which maps classes.
      def clear_reloadable_connections!
        synchronize do
          @reserved_connections = {}
          @connections.each do |conn|
            checkin conn
            conn.disconnect! if conn.requires_reloading?
          end
          @connections.delete_if do |conn|
            conn.requires_reloading?
          end
        end
      end

      # Verify active connections and remove and disconnect connections
      # associated with stale threads.
      def verify_active_connections! #:nodoc:
        synchronize do
          @connections.each do |connection|
            connection.verify!
          end
        end
      end

      def clear_stale_cached_connections! # :nodoc:
      end
      deprecate :clear_stale_cached_connections!

      # Check-out a database connection from the pool, indicating that you want
      # to use it. You should call #checkin when you no longer need this.
      #
      # This is done by either returning and leasing existing connection, or by
      # creating a new connection and leasing it.
      #
      # If all connections are leased and the pool is at capacity (meaning the
      # number of currently leased connections is greater than or equal to the
      # size limit set), an ActiveRecord::PoolFullError exception will be raised.
      #
      # Returns: an AbstractAdapter object.
      #
      # Raises:
      # - PoolFullError: no connection can be obtained from the pool.
      def checkout
        # Checkout an available connection
        synchronize do
          # Try to find a connection that hasn't been leased, and lease it
          conn = connections.find { |c| c.lease }

          # If all connections were leased, and we have room to expand,
          # create a new connection and lease it.
          if !conn && connections.size < size
            conn = checkout_new_connection
            conn.lease
          end

          if conn
            checkout_and_verify conn
          else
            raise PoolFullError.new(size, timeout)
          end
        end
      end

      # Check-in a database connection back into the pool, indicating that you
      # no longer need this connection.
      #
      # +conn+: an AbstractAdapter object, which was obtained by earlier by
      # calling +checkout+ on this pool.
      def checkin(conn)
        synchronize do
          conn.run_callbacks :checkin do
            conn.expire
          end
        end
      end

      # Remove a connection from the connection pool.  The connection will
      # remain open and active but will no longer be managed by this pool.
      def remove(conn)
        synchronize do
          @connections.delete conn

          # FIXME: we might want to store the key on the connection so that removing
          # from the reserved hash will be a little easier.
          thread_id = @reserved_connections.keys.find { |k|
            @reserved_connections[k] == conn
          }
          @reserved_connections.delete thread_id if thread_id
        end
      end

      # Removes dead connections from the pool.  A dead connection can occur
      # if a programmer forgets to close a connection at the end of a thread
      # or a thread dies unexpectedly.
      def reap
        synchronize do
          stale = Time.now - @timeout
          connections.dup.each do |conn|
            remove conn if conn.in_use? && stale > conn.last_use && !conn.active?
          end
        end
      end

      private

      def new_connection
        ActiveRecord::Base.send(spec.adapter_method, spec.config)
      end

      def current_connection_id #:nodoc:
        ActiveRecord::Base.connection_id ||= Thread.current.object_id
      end

      def checkout_new_connection
        raise ConnectionNotEstablished unless @automatic_reconnect

        c = new_connection
        c.pool = self
        @connections << c
        c
      end

      def checkout_and_verify(c)
        c.run_callbacks :checkout do
          c.verify!
        end
        c
      end

      def active_connections
        @connections.find_all { |c| c.in_use? }
      end
    end

    # ConnectionHandler is a collection of ConnectionPool objects. It is used
    # for keeping separate connection pools for Active Record models that connect
    # to different databases.
    #
    # For example, suppose that you have 5 models, with the following hierarchy:
    #
    #  |
    #  +-- Book
    #  |    |
    #  |    +-- ScaryBook
    #  |    +-- GoodBook
    #  +-- Author
    #  +-- BankAccount
    #
    # Suppose that Book is to connect to a separate database (i.e. one other
    # than the default database). Then Book, ScaryBook and GoodBook will all use
    # the same connection pool. Likewise, Author and BankAccount will use the
    # same connection pool. However, the connection pool used by Author/BankAccount
    # is not the same as the one used by Book/ScaryBook/GoodBook.
    #
    # Normally there is only a single ConnectionHandler instance, accessible via
    # ActiveRecord::Base.connection_handler. Active Record models use this to
    # determine that connection pool that they should use.
    class ConnectionHandler
      attr_reader :connection_pools

      def initialize(pools = {})
        @connection_pools = pools
        @class_to_pool    = {}
      end

      def establish_connection(name, spec)
        @connection_pools[spec] ||= ConnectionAdapters::ConnectionPool.new(spec)
        @class_to_pool[name] = @connection_pools[spec]
      end

      # Returns true if there are any active connections among the connection
      # pools that the ConnectionHandler is managing.
      def active_connections?
        connection_pools.values.any? { |pool| pool.active_connection? }
      end

      # Returns any connections in use by the current thread back to the pool,
      # and also returns connections to the pool cached by threads that are no
      # longer alive.
      def clear_active_connections!
        @connection_pools.each_value {|pool| pool.release_connection }
      end

      # Clears the cache which maps classes.
      def clear_reloadable_connections!
        @connection_pools.each_value {|pool| pool.clear_reloadable_connections! }
      end

      def clear_all_connections!
        @connection_pools.each_value {|pool| pool.disconnect! }
      end

      # Verify active connections.
      def verify_active_connections! #:nodoc:
        @connection_pools.each_value {|pool| pool.verify_active_connections! }
      end

      # Locate the connection of the nearest super class. This can be an
      # active or defined connection: if it is the latter, it will be
      # opened and set as the active connection for the class it was defined
      # for (not necessarily the current class).
      def retrieve_connection(klass) #:nodoc:
        pool = retrieve_connection_pool(klass)
        (pool && pool.connection) or raise ConnectionNotEstablished
      end

      # Returns true if a connection that's accessible to this class has
      # already been opened.
      def connected?(klass)
        conn = retrieve_connection_pool(klass)
        conn && conn.connected?
      end

      # Remove the connection for this class. This will close the active
      # connection and the defined connection (if they exist). The result
      # can be used as an argument for establish_connection, for easily
      # re-establishing the connection.
      def remove_connection(klass)
        pool = @class_to_pool.delete(klass.name)
        return nil unless pool

        @connection_pools.delete pool.spec
        pool.automatic_reconnect = false
        pool.disconnect!
        pool.spec.config
      end

      def retrieve_connection_pool(klass)
        pool = @class_to_pool[klass.name]
        return pool if pool
        return nil if ActiveRecord::Model == klass
        retrieve_connection_pool klass.active_record_super
      end
    end

    class ConnectionManagement
      def initialize(app)
        @app = app
      end

      def call(env)
        testing = env.key?('rack.test')

        response = @app.call(env)
        response[2] = ::Rack::BodyProxy.new(response[2]) do
          ActiveRecord::Base.clear_active_connections! unless testing
        end

        response
      rescue
        ActiveRecord::Base.clear_active_connections! unless testing
        raise
      end
    end
  end
end
