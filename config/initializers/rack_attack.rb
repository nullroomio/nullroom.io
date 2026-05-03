class Rack::Attack
  self.cache.store = if Rails.env.test?
    ActiveSupport::Cache::MemoryStore.new
  else
    ActiveSupport::Cache::RedisCacheStore.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0"))
  end

  throttle("rooms/create", limit: 5, period: 60.seconds) do |req|
    req.ip if req.post? && req.path == "/rooms"
  end

  throttle("blind_tokens/session", limit: 3, period: 60.seconds) do |req|
    req.ip if req.post? && req.path == "/blind_tokens/session"
  end

  throttle("landing_page", limit: 60, period: 60.seconds) do |req|
    req.ip if req.get? && req.path == "/"
  end

  throttle("health", limit: 5, period: 60.seconds) do |req|
    req.ip if req.get? && req.path == "/up"
  end

  self.throttled_responder = lambda do |request|
    match_data = request.env["rack.attack.match_data"] || {}
    retry_after = match_data[:period].to_i

    [
      429,
      {
        "Content-Type" => "application/json",
        "Retry-After" => retry_after.to_s
      },
      [ { error: "Rate limit exceeded. Try again later." }.to_json ]
    ]
  end
end
