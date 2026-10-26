require "rake"
require_relative "runtime"
require_relative "toolkit/operations"
module Toolkit
  class Tasks
    extend Rake::DSL
    def self.install
      Operations::TASKS.each do |name, description|
        desc description
        task(name) { |_, args| Operations.new.call(name, args.extras) }
      end
      task default: "doctor"
    end
  end
end
