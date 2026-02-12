require "timeout"

# HealthController provides application and Redis health checks via the /up endpoint.
#
# This controller is used by load balancers and uptime monitors to verify the app is live
# and can write to Redis. A write test (SET + DEL) is performed on each request to catch
# readonly replica issues early, preventing production errors.
#
# Rate limiting (1 req/sec per IP) is applied to prevent abuse and excessive Redis load.
#
# Responses:
# - 200 OK: App and Redis are healthy
# - 500 Internal Server Error: Redis is unavailable or readonly
# - 429 Too Many Requests: Rate limit exceeded (1 req/sec per IP)
class HealthController < ApplicationController
  MAX_REQUESTS_PER_SEC = 1
  @@rate_limit_tracker = {}
  @@rate_limit_lock = Mutex.new

  before_action :rate_limit_check

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

  # Enforces a 1 request per second per IP limit on the /up endpoint.
  # Uses an in-memory tracker (not Redis-dependent) with a Mutex for thread safety.
  # Cleans up old entries automatically when checking each request.
  # Returns 429 (Too Many Requests) if the limit is exceeded.
  def rate_limit_check
    ip = request.remote_ip
    now = Time.now.to_f

    @@rate_limit_lock.synchronize do
      # Clean up old entries (older than 1 second)
      @@rate_limit_tracker[ip]&.reject! { |timestamp| now - timestamp > 1.0 }

      # Check if limit exceeded
      if @@rate_limit_tracker[ip]&.size.to_i >= MAX_REQUESTS_PER_SEC
        render json: { status: "rate_limited" }, status: :too_many_requests
        return
      end

      # Record this request
      @@rate_limit_tracker[ip] ||= []
      @@rate_limit_tracker[ip] << now
    end
  end

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
