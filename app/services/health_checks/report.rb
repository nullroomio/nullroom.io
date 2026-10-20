# frozen_string_literal: true

require "json"

module HealthChecks
  # Builds the status report: runs every component check in parallel, caches
  # the result in Redis, and rolls component states up into an overall state.
  #
  # Requests never wait on checks: #current returns the cached report (or nil
  # before the first run) and, when it is older than MAX_AGE, starts a refresh
  # in a background thread. At most one refresh runs at a time — across
  # processes via a Redis lock, within a process via REFRESHING — so request
  # volume never drives TURN allocations, Tor round-trips or TLS handshakes.
  #
  # The cached report keeps reason codes and details for operators
  # (`redis-cli get status:report`); the public page and JSON show states only.
  #
  # Critical components (rooms can't work without them) make the overall state
  # "down"; anything else that isn't ok makes it "degraded".
  class Report
    Component = Data.define(:id, :name, :group, :critical, :check)

    CACHE_KEY = "status:report"
    MAX_AGE = 60
    # Kept past MAX_AGE so a concurrent request can serve it while another refreshes.
    CACHE_TTL = 10 * 60
    LOCK_TTL = 30

    REFRESHING = Concurrent::AtomicBoolean.new
    # Last report per cache key, so the page keeps working while Redis is down.
    LOCAL_CACHE = Concurrent::Map.new

    def self.current
      new.current
    end

    # Overall state is ok only when every critical component is ok.
    def self.healthy?(report)
      report["components"].select { |component| component["critical"] }.all? { |component| component["status"] == "ok" }
    end

    def self.default_components
      turn_host = ENV["COTURN_HOST"].presence || CoturnService::TURN_HOST
      origin_host = ENV["NULLROOM_ORIGIN_HOST"].presence
      apex = URI(Nullroom::Config::CANONICAL_ORIGIN).host

      components = [
        Component.new("redis", "Redis", "core", true, RedisCheck.new),
        Component.new("signaling", "Signaling relay", "core", true, CablePubsubCheck.new)
      ]

      if Nullroom::Config::TURN_PROVIDER == "cloudflare"
        components << Component.new("turn", "TURN relay (Cloudflare)", "relay", true, CloudflareTurnCheck.new)
      else
        components << Component.new("stun", "STUN (UDP 3478)", "relay", true, StunCheck.new(host: turn_host))
        components << Component.new("turn", "TURN relay (TLS 443)", "relay", true,
          TurnAllocateCheck.new(host: turn_host, server_name: CoturnService::TURN_HOST))
        components << Component.new("cert_turn", CoturnService::TURN_HOST, "certificates", true,
          TlsCertCheck.new(host: turn_host, server_name: CoturnService::TURN_HOST))
      end

      if origin_host
        components << Component.new("cert_origin", "#{apex} (origin)", "certificates", true,
          TlsCertCheck.new(host: origin_host, server_name: apex))
      end

      components + [
        Component.new("cert_edge", "#{apex} (edge)", "certificates", true, TlsCertCheck.new(host: apex, server_name: apex)),
        Component.new("tor", "Tor proxy", "donations", false,
          TorCheck.new(host: MoneroPaymentService.tor_socks_host, port: MoneroPaymentService.tor_socks_port)),
        Component.new("monero", "Monero wallet RPC", "donations", false, MoneroRpcCheck.new),
        Component.new("blind_key", "Receipt signing key", "donations", false, BlindTokenKeyCheck.new),
        Component.new("manifest", "Integrity manifest", "integrity", false, IntegrityManifestCheck.new)
      ]
    end

    # @param async [Boolean] refresh in a background thread (false runs it inline, for tests)
    def initialize(components: self.class.default_components, cache_key: CACHE_KEY, async: true)
      @components = components
      @cache_key = cache_key
      @async = async
    end

    # Returns the cached report (possibly up to CACHE_TTL old), or nil when no
    # check has completed yet. Starts a background refresh when it is stale.
    def current
      cached = read_cache
      refresh if cached.nil? || age(cached) >= MAX_AGE
      @async ? cached : read_cache
    end

    # Public view of a report: component states only, no reason codes or details.
    def self.public_view(report)
      report.slice("status", "checked_at").merge(
        "components" => report["components"].map { |component| component.slice("id", "name", "group", "critical", "status") }
      )
    end

    def build
      results = @components.map { |component| Thread.new { component.check.run } }.map(&:value)

      components = @components.zip(results).map do |component, result|
        {
          "id" => component.id,
          "name" => component.name,
          "group" => component.group,
          "critical" => component.critical,
          "status" => result.status,
          "reason" => result.reason,
          "details" => result.details.stringify_keys
        }
      end

      { "status" => overall(components), "checked_at" => Time.now.utc.iso8601, "components" => components }
    end

    private

    def refresh
      return unless REFRESHING.make_true
      return REFRESHING.make_false unless acquire_lock

      work = lambda do
        write_cache(build)
      ensure
        release_lock
        REFRESHING.make_false
      end

      @async ? Thread.new { Rails.application.executor.wrap(&work) } : work.call
    end

    def overall(components)
      return "down" if components.any? { |component| component["critical"] && component["status"] == "down" }
      return "degraded" if components.any? { |component| component["status"] != "ok" }

      "ok"
    end

    def age(report)
      Time.now - Time.iso8601(report["checked_at"])
    end

    def read_cache
      raw = REDIS.get(@cache_key)
      raw ? JSON.parse(raw) : nil
    rescue Redis::BaseError, JSON::ParserError
      LOCAL_CACHE[@cache_key]
    end

    def write_cache(report)
      LOCAL_CACHE[@cache_key] = report
      REDIS.set(@cache_key, report.to_json, ex: CACHE_TTL)
    rescue Redis::BaseError
      nil
    end

    # Without Redis, the in-process REFRESHING flag alone bounds refreshes.
    def acquire_lock
      REDIS.set(lock_key, "1", nx: true, ex: LOCK_TTL)
    rescue Redis::BaseError
      true
    end

    def release_lock
      REDIS.del(lock_key)
    rescue Redis::BaseError
      nil
    end

    def lock_key
      "#{@cache_key}:lock"
    end
  end
end
