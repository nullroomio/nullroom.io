# frozen_string_literal: true

require "securerandom"

module HealthChecks
  # Round-trips a message through ActionCable's pub/sub adapter — the path that
  # relays WebRTC signaling between the two peers of a room.
  class CablePubsubCheck < Check
    WAIT_SECONDS = 2

    def call
      pubsub = ActionCable.server.pubsub
      channel = "health:#{SecureRandom.hex(8)}"
      token = SecureRandom.hex(8)
      subscribed = Queue.new
      received = Queue.new
      handler = ->(message) { received << message }

      pubsub.subscribe(channel, handler, -> { subscribed << true })
      return Result.down("subscribe_failed") unless subscribed.pop(timeout: WAIT_SECONDS)

      pubsub.broadcast(channel, token)
      received.pop(timeout: WAIT_SECONDS) == token ? Result.ok : Result.down("message_lost")
    ensure
      pubsub&.unsubscribe(channel, handler) if handler
    end
  end
end
