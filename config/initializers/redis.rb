# Configure Redis connection for nullroom
# Used for room management and ActionCable in production

REDIS = Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0"))
