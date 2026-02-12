class RoomsController < ApplicationController
  # Skip CSRF token verification for room creation API
  skip_before_action :verify_authenticity_token, only: [ :create ]

  def index
    # Landing page - single "Create Room" button
  end

  def create
    # Generate unique room UUID
    room_id = SecureRandom.uuid

    # Store room in Redis with 30-minute TTL
    REDIS.setex("room:#{room_id}", 30.minutes.to_i, "active")

    # Initialize room counter (nobody joined yet)
    REDIS.setex("room:#{room_id}:count", 31.minutes.to_i, "0")

    # Fetch ephemeral TURN credentials from Cloudflare
    begin
      service = CloudflareTurnService.new
      turn_servers = service.generate_ice_servers
    rescue StandardError => e
      Rails.logger.error("Failed to fetch Cloudflare TURN credentials: #{e.message}")
      # Fallback to empty array - client should handle gracefully
      turn_servers = []
    end

    # Return JSON response (NOT a redirect)
    render json: {
      room_id: room_id,
      turn_servers: turn_servers
    }
  end

  def show
    @room_id = params[:id]

    # Verify room exists in Redis
    unless REDIS.exists?("room:#{@room_id}")
      render plain: "Invalid room link", status: :not_found
      return
    end

    # Fetch ephemeral TURN credentials from Cloudflare
    begin
      service = CloudflareTurnService.new
      @ice_servers = service.generate_ice_servers
    rescue StandardError => e
      Rails.logger.error("Failed to fetch Cloudflare TURN credentials in show: #{e.message}")
      # Fallback to empty array - client should handle gracefully
      @ice_servers = []
    end

    # Room view is rendered; encryption key comes from URL fragment (never sent to server)
  end
end
