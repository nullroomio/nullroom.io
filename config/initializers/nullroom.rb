# frozen_string_literal: true

# Nullroom application configuration
module Nullroom
  module Config
    # Room lifecycle behavior:
    # When true: room is destroyed immediately when any peer leaves (no rejoin possible via browser history)
    # When false: room remains active until TTL expires (peers can reconnect via back/history)
    DESTROY_ROOM_ON_PEER_LEAVE = false

    # Maximum P2P file transfer size in bytes.
    # Override with NULLROOM_FILE_TRANSFER_SIZE_LIMIT_BYTES in environment.
    FILE_TRANSFER_SIZE_LIMIT_BYTES = ENV.fetch("NULLROOM_FILE_TRANSFER_SIZE_LIMIT_BYTES", 16 * 1024 * 1024).to_i
  end
end
