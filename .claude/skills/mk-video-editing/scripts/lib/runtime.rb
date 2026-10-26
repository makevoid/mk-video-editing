$LOAD_PATH.unshift(__dir__)
require "uri"
Dir[File.join(__dir__, "media", "*.rb")].sort.each { |f| require f }
require "fal/client"
require "fal/openapi"
Dir[File.join(__dir__, "fal", "models", "*.rb")].sort.each { |f| require f }
