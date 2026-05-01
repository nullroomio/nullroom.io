class HandshakesController < ApplicationController
  skip_before_action :verify_authenticity_token

  # POST /handshakes/:id
  # Stores an encrypted blob in Redis under the given identifier.
  def create
    identifier = params[:id]
    blob = params[:blob]

    unless valid_identifier?(identifier)
      render json: { error: "Invalid identifier" }, status: :unprocessable_entity
      return
    end

    unless blob.present? && blob.bytesize <= 2048
      render json: { error: "Invalid or oversized blob" }, status: :unprocessable_entity
      return
    end

    key = "handshake:#{identifier}"

    # Don't overwrite an existing handshake
    if REDIS.exists?(key)
      render json: { error: "Identifier already in use" }, status: :conflict
      return
    end

    REDIS.setex(key, 180, blob)
    head :created
  end

  # GET /handshakes/:id
  # Returns the encrypted blob and immediately deletes it (one-time read).
  def show
    identifier = params[:id]

    unless valid_identifier?(identifier)
      render json: { error: "Invalid identifier" }, status: :unprocessable_entity
      return
    end

    key = "handshake:#{identifier}"
    blob = REDIS.get(key)

    unless blob
      head :not_found
      return
    end

    # Delete immediately — one-time use
    REDIS.del(key)

    render json: { blob: blob }
  end

  private

  def valid_identifier?(id)
    id.present? && id.match?(/\A[0-9a-f]{64}\z/)
  end
end
