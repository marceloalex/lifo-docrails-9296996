require 'active_support/logger'
require_dependency 'models/course'

module ARTest
  def self.connection_name
    ENV['ARCONN'] || config['default_connection']
  end

  def self.connection_config
    config['connections'][connection_name]
  end

  def self.connect
    puts "Using #{connection_name} with Identity Map #{ActiveRecord::IdentityMap.enabled? ? 'on' : 'off'}"
    ActiveRecord::Model.logger = ActiveSupport::Logger.new("debug.log")
    ActiveRecord::Model.configurations = connection_config
    ActiveRecord::Model.establish_connection 'arunit'
    Course.establish_connection 'arunit2'
  end
end
