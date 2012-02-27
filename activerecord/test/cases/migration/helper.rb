require "cases/helper"

module ActiveRecord
  class Migration
    class << self
      attr_accessor :message_count
    end

    def puts(text="")
      ActiveRecord::Migration.message_count ||= 0
      ActiveRecord::Migration.message_count += 1
    end

    module TestHelper
      attr_reader :connection, :table_name

      class TestModel < ActiveRecord::Base
        self.table_name = 'test_models'
      end

      def setup
        super
        @connection = ActiveRecord::Base.connection
        connection.create_table :test_models do |t|
          t.timestamps
        end

        TestModel.reset_column_information
      end

      def teardown
        super
        TestModel.reset_table_name
        TestModel.reset_sequence_name
        connection.drop_table :test_models rescue nil
      end

      private
      def add_column(*args)
        connection.add_column(*args)
      end

      def remove_column(*args)
        connection.remove_column(*args)
      end

      def rename_column(*args)
        connection.rename_column(*args)
      end

      def add_index(*args)
        connection.add_index(*args)
      end

      def change_column(*args)
        connection.change_column(*args)
      end

      def rename_table(*args)
        connection.rename_table(*args)
      end
    end
  end
end
