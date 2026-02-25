class RoomsChannel < ApplicationCable::Channel
  def subscribed
    @joined = false
    @room_id = params[:room_id]

    # Check if room exists in Redis
    unless REDIS.exists?("room:#{@room_id}")
      reject
      return
    end

    # Increment connection counter for this room
    count = REDIS.incr("room:#{@room_id}:count")

    # Reject if more than 2 people try to join
    if count > 2
      REDIS.decr("room:#{@room_id}:count")
      reject
      return
    end

    # Generate unique connection identifier for this subscription
    @connection_id = SecureRandom.uuid

    # Subscribe to the room's broadcast stream
    stream_from "rooms:#{@room_id}"
    @joined = true

    # Send initialization message with initiator status
    # First person (count=1) is initiator, second person (count=2) is not
    transmit({ type: "init", initiator: count == 1, connection_id: @connection_id, file_sharing: true })

    # If we're the second person, notify first person that we're ready
    if count == 2
      ActionCable.server.broadcast(
        "rooms:#{@room_id}",
        { type: "peer_ready" }
      )
    end
  end

  def send_signal(data)
    # Relay WebRTC signaling data to all other subscribers
    # The connection_id allows clients to filter out their own signals
    ActionCable.server.broadcast(
      "rooms:#{@room_id}",
      { type: "signal", data: data["data"], connection_id: @connection_id }
    )
  end

  def unsubscribed
    return unless @room_id && @joined

    room_key = "room:#{@room_id}"
    count_key = "room:#{@room_id}:count"

    # Ignore duplicate unsubscribe callbacks after room has already been destroyed.
    return unless REDIS.exists?(room_key)

    # Decrement counter so we know if another peer is still present.
    remaining = REDIS.decr(count_key)

    # Notify the remaining peer that we're leaving before destroying room keys.
    if remaining && remaining >= 1
      ActionCable.server.broadcast(
        "rooms:#{@room_id}",
        { type: "peer_left", connection_id: @connection_id }
      )
    end

    # Optionally destroy room immediately when any peer leaves (prevents rejoin via browser history).
    # When disabled, room remains active until TTL expires.
    if Nullroom::Config::DESTROY_ROOM_ON_PEER_LEAVE
      REDIS.del(room_key)
      REDIS.del(count_key)
    end
  end

  # Called by the client before starting a DataChannel file transfer.
  # Acts as the server-side gate: authorises or rejects based on metadata.
  # Actual file bytes NEVER touch the server — they travel P2P over the DataChannel.
  def initiate_file_transfer(data)
    if authorized_for_file_transfer?(data["metadata"])
      # Authorised — let the client proceed with the DataChannel transfer
      transmit({ type: "file_transfer_authorized" })
    else
      # Soft rejection — only the requesting sender receives this
      transmit({ type: "file_transfer_error", error: "Beta limit exceeded: Files must be under 24 MB." })
    end
  end

  private

  # Stubbed gate for the Beta phase.
  # The structure is ready for Blind Token (JWT) enforcement in the Pro launch.
  def authorized_for_file_transfer?(metadata)
    # 1. Enforce the Beta size limit (24 MiB)
    return false if metadata.to_h["file_size"].to_i > 25_165_824

    # 2. TODO: Implement BlindSignatureService.verify?(token, sig) for Pro launch.
    #    For now, all P2P file transfers are permitted during the Beta phase.
    true
  end
end
