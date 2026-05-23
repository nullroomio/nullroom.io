class RoomsController < ApplicationController
  # Skip CSRF token verification for room creation API
  skip_before_action :verify_authenticity_token, only: [ :create ]

  def index
    # Landing page - single "Create Room" button
  end

  def create
    # Generate unique room UUID
    room_id = SecureRandom.uuid

    # Store room in Redis with configured TTL
    REDIS.setex("room:#{room_id}", Nullroom::Config::ROOM_TTL_SECONDS, "active")

    # Initialize room counter (nobody joined yet)
    REDIS.setex("room:#{room_id}:count", Nullroom::Config::ROOM_COUNT_TTL_SECONDS, "0")

    # Fetch ephemeral TURN credentials
    begin
      service = turn_service
      turn_servers = service.generate_ice_servers
    rescue StandardError => e
      Rails.logger.warn("TURN credential generation failed (#{Nullroom::Config::TURN_PROVIDER}): #{e.message}")
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
    @room_ttl_seconds = Nullroom::Config::ROOM_TTL_SECONDS

    # Verify room exists in Redis
    unless REDIS.exists?("room:#{@room_id}")
      render plain: "Invalid room link", status: :not_found
      return
    end

    # Fetch ephemeral TURN credentials
    begin
      service = turn_service
      @ice_servers = service.generate_ice_servers
    rescue StandardError => e
      Rails.logger.warn("TURN credential generation failed (#{Nullroom::Config::TURN_PROVIDER}): #{e.message}")
      @ice_servers = []
    end

    # Room view is rendered; encryption key comes from URL fragment (never sent to server)
  end

  private

  def turn_service
    if Nullroom::Config::TURN_PROVIDER == "cloudflare"
      CloudflareTurnService.new
    else
      CoturnService.new
    end
  end
end
