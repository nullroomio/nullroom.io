require "timeout"

# HealthController provides application and Redis health checks via the /up endpoint.
#
# This controller is used by load balancers and uptime monitors to verify the app is live
# and can write to Redis. A write test (SET + DEL) is performed on each request to catch
# readonly replica issues early, preventing production errors.
#
# Responses:
# - 200 OK: App and Redis are healthy
# - 500 Internal Server Error: Redis is unavailable or readonly
# - 429 Too Many Requests: Rate limit exceeded by Rack::Attack
class HealthController < ApplicationController
  # GET /up
  # Performs a Redis write check (SET + EXPIRE + DEL) and returns JSON status.
  # Catches readonly replicas and connection failures before they impact user traffic.
  def show
    ok = redis_write_check

    if ok
      render json: { status: "ok" }, status: :ok
    else
      render json: { status: "error" }, status: :internal_server_error
    end
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
end
