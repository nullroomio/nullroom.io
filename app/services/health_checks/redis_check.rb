# frozen_string_literal: true

require "securerandom"

module HealthChecks
  # Rooms, handshakes, rate limits and ActionCable all live in Redis.
  # Beyond a write round-trip, flags memory pressure and evictions: an evicted
  # room key kills a conversation before its TTL.
  #
  # Uses its own short-lived connection: if the check's timeout fires mid-command,
  # only this connection is left in a bad state, never the app's shared REDIS.
  class RedisCheck < Check
    EVICTED_KEYS_KEY = "health:evicted_keys"
    MEMORY_PRESSURE_RATIO = 0.9

    def initialize(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0"))
      @url = url
    end

    def call
      @redis = Redis.new(url: @url, timeout: 1, reconnect_attempts: 0)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      key = "health:#{SecureRandom.hex(8)}"
      @redis.set(key, "1", ex: 5)
      written = @redis.get(key) == "1"
      @redis.del(key)
      return Result.down("write_failed") unless written

      details = { latency_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round }

      return Result.degraded("evicting_keys", **details) if evictions_since_last_check?
      return Result.degraded("memory_pressure", **details) if memory_pressure?

      Result.ok(**details)
    rescue Redis::BaseError
      Result.down("unavailable")
    ensure
      @redis&.close
    end

    private

    def evictions_since_last_check?
      evicted = @redis.info("stats")["evicted_keys"].to_i
      previous = @redis.set(EVICTED_KEYS_KEY, evicted, get: true, ex: 24 * 60 * 60)
      previous.present? && evicted > previous.to_i
    end

    def memory_pressure?
      memory = @redis.info("memory")
      max = memory["maxmemory"].to_i
      max.positive? && memory["used_memory"].to_i >= max * MEMORY_PRESSURE_RATIO
    end
  end
end
