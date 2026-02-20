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
    transmit({ type: "init", initiator: count == 1, connection_id: @connection_id })

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
end
