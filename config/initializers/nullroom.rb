# frozen_string_literal: true

# Nullroom application configuration
module Nullroom
  module Config
    def self.integer_env(name, default)
      Integer(ENV.fetch(name, default).to_s, 10)
    rescue ArgumentError
      raise "Invalid integer value for #{name}"
    end

    # Room TTL in seconds (default: 15 minutes).
    # Override with NULLROOM_ROOM_TTL_SECONDS in environment.
    ROOM_TTL_SECONDS = integer_env("NULLROOM_ROOM_TTL_SECONDS", 15 * 60)

    # Counter key TTL is slightly longer than room TTL to avoid edge races.
    ROOM_COUNT_TTL_SECONDS = ROOM_TTL_SECONDS + 60

    # Room lifecycle behavior:
    # When true: room is destroyed immediately when any peer leaves (no rejoin possible via browser history)
    # When false: room remains active until TTL expires (peers can reconnect via back/history)
    DESTROY_ROOM_ON_PEER_LEAVE = false

    # Maximum P2P file transfer size in bytes.
    # Override with NULLROOM_FILE_TRANSFER_SIZE_LIMIT_BYTES in environment.
    FILE_TRANSFER_SIZE_LIMIT_BYTES = integer_env("NULLROOM_FILE_TRANSFER_SIZE_LIMIT_BYTES", 16 * 1024 * 1024)

    # Donation amount in piconero (1e-12 XMR).
    # Default: 0.004 XMR.
    DONATION_AMOUNT_PICONERO = integer_env("NULLROOM_DONATION_AMOUNT_PICONERO", 4_000_000_000)

    # Monero confirmations required before issuing a blind signature.
    DONATION_CONFIRMATIONS_REQUIRED = integer_env("NULLROOM_DONATION_CONFIRMATIONS_REQUIRED", 10)

    # Seconds before a payment session expires.
    DONATION_PAYMENT_SESSION_TTL_SECONDS = integer_env("NULLROOM_DONATION_PAYMENT_SESSION_TTL_SECONDS", 30 * 60)

    # Marks a donation receipt token as spent for this duration.
    DONATION_SPENT_TOKEN_TTL_SECONDS = integer_env("NULLROOM_DONATION_SPENT_TOKEN_TTL_SECONDS", 24 * 60 * 60)

    # How long a successful donation unlock is kept in the browser session.
    DONATION_SESSION_UNLOCK_TTL_SECONDS = integer_env("NULLROOM_DONATION_SESSION_UNLOCK_TTL_SECONDS", 12 * 60 * 60)
  end
end
