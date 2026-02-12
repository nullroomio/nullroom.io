# Middleware to skip session creation and cookies for ActionCable WebSocket connections.
#
# Purpose:
# - Keeps WebSocket handshakes stateless by preventing Rails from setting/reading cookies
# - Improves privacy: no session identifier associated with WebRTC signaling
# - Reduces memory overhead: no session data stored for ActionCable subscribers
#
# Usage:
# - Automatically inserted in config/application.rb before ActionDispatch::Session::CookieStore
# - Intercepts /cable requests and sets env["rack.session.options"][:skip] = true
#
# Result:
# - ActionCable subscribers are identified only by their random token_id (set in connection.rb)
# - No cookies sent to or from the server for WebSocket connections
module Middleware
  class SkipSessionForCable
    # Initialize the middleware.
    #
    # @param app [Object] The Rack application
    # @param path [String] The path prefix to match (default: "/cable")
    def initialize(app, path: "/cable")
      @app = app
      @path = path
    end

    # Process the request and skip session middleware if it's an ActionCable connection.
    #
    # @param env [Hash] The Rack environment
    # @return [Array] The Rack response
    def call(env)
      if env["PATH_INFO"]&.start_with?(@path)
        env["rack.session.options"] ||= {}
        env["rack.session.options"][:skip] = true
      end

      @app.call(env)
    end
  end
end

