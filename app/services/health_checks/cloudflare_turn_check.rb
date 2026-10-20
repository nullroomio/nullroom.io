# frozen_string_literal: true

module HealthChecks
  # When NULLROOM_TURN_PROVIDER=cloudflare, relay credentials come from the
  # Cloudflare API; rooms silently lose the relay if that call fails.
  class CloudflareTurnCheck < Check
    def call
      servers = CloudflareTurnService.new.generate_ice_servers(ttl: 60)
      servers.any? { |server| server["username"] } ? Result.ok : Result.down("no_relay_servers")
    rescue RuntimeError
      Result.down("provider_error")
    end
  end
end
