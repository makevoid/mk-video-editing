#!/usr/bin/env ruby
abort "mk-video-editing MCP server needs Ruby 3.2+ (found #{RUBY_VERSION}); put Homebrew Ruby first in PATH" if Gem::Version.new(RUBY_VERSION) < Gem::Version.new("3.2")
# Start without Bundler so the plugin can connect before a video project is set up.
require_relative "lib/toolkit/mcp_server"
Toolkit::McpServer.new.run if $PROGRAM_NAME == __FILE__
