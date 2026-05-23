require "timeout"
require "socket"

# HealthController provides application health checks via the /up endpoint.
#
# This controller is used by load balancers and uptime monitors to verify the app is live.
# It checks both hard dependencies (Redis) and soft dependencies (Coturn) and returns
# per-service status in the response body.
#
# Hard dependencies affect the HTTP status code (500 if down).
# Soft dependencies are informational only (reported but don't affect status code).
#
# Responses:
# - 200 OK: Hard dependencies are healthy (app is functional)
# - 500 Internal Server Error: A hard dependency is unavailable
# - 429 Too Many Requests: Rate limit exceeded by Rack::Attack
class HealthController < ApplicationController
  COTURN_HOST = ENV.fetch("COTURN_HOST", "127.0.0.1")
  COTURN_PORTS = [ 3478, 443 ].freeze

  # GET /up
  # Returns per-service health status as JSON.
  # HTTP status is based only on hard dependencies (Redis).
  # Coturn is a soft dependency — reported but does not affect HTTP status.
  def show
    redis_ok = redis_write_check
    coturn_ok = coturn_port_check

    services = {
      redis: redis_ok ? "ok" : "error",
      coturn: coturn_ok ? "ok" : "error"
    }

    # Only Redis is a hard dependency — Coturn is informational
    status_code = redis_ok ? :ok : :internal_server_error
    overall = redis_ok ? "ok" : "error"

    render json: { status: overall, services: services }, status: status_code
  end

  private

  # Performs a Redis write test: SET a temporary key with a 5-second expiry, then DEL it.
  # Returns true if successful, false if Redis is unavailable, readonly, or times out.
  # Timeout is set to 1 second to avoid blocking the health check indefinitely.
  def redis_write_check
    key = "health:#{SecureRandom.hex(8)}"

    Timeout.timeout(1) do
      REDIS.set(key, "1", ex: 5)
      REDIS.del(key)
    end

    true
  rescue Redis::BaseError, Timeout::Error
    false
  end

  # Checks if Coturn STUN/TURN ports are listening via TCP connect.
  # Verifies port 3478 (STUN/TURN) and 443 (TURNS/TLS) on the floating IP.
  # Returns true if all ports accept connections, false otherwise.
  # Timeout is set to 1 second total for both port checks.
  def coturn_port_check
    Timeout.timeout(1) do
      COTURN_PORTS.each do |port|
        Socket.tcp(COTURN_HOST, port, connect_timeout: 1) { |s| s.close }
      end
    end

    true
  rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Timeout::Error, SocketError
    false
  end
end
