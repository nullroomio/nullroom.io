# frozen_string_literal: true

# Nullroom application configuration
module Nullroom
  module Config
    # Room TTL in seconds (default: 15 minutes).
    # Override with NULLROOM_ROOM_TTL_SECONDS in environment.
    ROOM_TTL_SECONDS = ENV.fetch("NULLROOM_ROOM_TTL_SECONDS", 15 * 60).to_i

    # Counter key TTL is slightly longer than room TTL to avoid edge races.
    ROOM_COUNT_TTL_SECONDS = ROOM_TTL_SECONDS + 60

    # Room lifecycle behavior:
    # When true: room is destroyed immediately when any peer leaves (no rejoin possible via browser history)
    # When false: room remains active until TTL expires (peers can reconnect via back/history)
    DESTROY_ROOM_ON_PEER_LEAVE = false

    # Maximum P2P file transfer size in bytes.
    # Override with NULLROOM_FILE_TRANSFER_SIZE_LIMIT_BYTES in environment.
    FILE_TRANSFER_SIZE_LIMIT_BYTES = ENV.fetch("NULLROOM_FILE_TRANSFER_SIZE_LIMIT_BYTES", 16 * 1024 * 1024).to_i
  end
end
