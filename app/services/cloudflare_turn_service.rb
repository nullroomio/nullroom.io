require "net/http"
require "json"

class CloudflareTurnService
  # Cloudflare TURN API endpoint
  TURN_API_BASE = "https://rtc.live.cloudflare.com/v1/turn/keys"

  def initialize
    @turn_key_id = Rails.application.credentials.dig(:cloudflare, :turn_key_id)
    @turn_api_token = Rails.application.credentials.dig(:cloudflare, :turn_api_token)

    raise "Cloudflare TURN credentials not configured" unless @turn_key_id && @turn_api_token
  end

  # Fetch short-lived TURN credentials from Cloudflare API
  # @param ttl [Integer] Time-to-live in seconds (default: 86400 = 24 hours)
  # @return [Hash] iceServers configuration ready for RTCPeerConnection
  def generate_ice_servers(ttl: 86400)
    url = URI("#{TURN_API_BASE}/#{@turn_key_id}/credentials/generate-ice-servers")
    http = Net::HTTP.new(url.host, url.port)
    http.use_ssl = true

    request = Net::HTTP::Post.new(url.path, {
      "Authorization" => "Bearer #{@turn_api_token}",
      "Content-Type" => "application/json"
    })

    request.body = JSON.generate({ ttl: ttl })

    begin
      response = http.request(request)

      unless response.is_a?(Net::HTTPSuccess)
        Rails.logger.error("Cloudflare TURN API error: #{response.code} - #{response.body}")
        raise "Failed to fetch TURN credentials from Cloudflare"
      end

      data = JSON.parse(response.body)

      # Cloudflare returns { iceServers: [...] }
      # Filter to avoid browser warning about too many STUN/TURN servers
      ice_servers = data["iceServers"]
      
      # Keep only primary ports to reduce server count
      # Remove alternate ports (53, 80) which are often blocked anyway
      optimized_servers = ice_servers.map do |server|
        if server["urls"]
          filtered_urls = server["urls"].reject do |url|
            url.include?(":53") || url.include?(":80")
          end
          server.merge("urls" => filtered_urls) if filtered_urls.any?
        else
          server
        end
      end.compact
      
      optimized_servers
    rescue StandardError => e
      Rails.logger.error("CloudflareTurnService error: #{e.message}")
      raise "Failed to generate TURN credentials: #{e.message}"
    end
  end
end
