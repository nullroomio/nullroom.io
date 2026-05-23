# frozen_string_literal: true

require "openssl"
require "base64"

class CoturnService
  # Generates ephemeral TURN credentials using HMAC shared-secret (RFC draft turn-rest).
  # Coturn validates these by recomputing the HMAC and checking the timestamp hasn't expired.

  TURN_HOST = ENV.fetch("NULLROOM_TURN_HOST", "turn.nullroom.io").freeze

  # Credential TTL slightly exceeds room lifetime (15 min) to cover clock skew and reconnects.
  DEFAULT_TTL = 30 * 60 # 30 minutes

  def initialize
    @secret = ENV.fetch("COTURN_SECRET")
  end

  # @param ttl [Integer] Credential lifetime in seconds (default: 30 minutes)
  # @return [Array<Hash>] ICE servers configuration ready for RTCPeerConnection
  def generate_ice_servers(ttl: DEFAULT_TTL)
    expiry = Time.now.to_i + ttl
    username = expiry.to_s
    password = Base64.strict_encode64(
      OpenSSL::HMAC.digest("SHA1", @secret, username)
    )

    [
      {
        "urls" => [ "stun:#{TURN_HOST}:3478" ]
      },
      {
        "urls" => [ "turns:#{TURN_HOST}:443?transport=tcp" ],
        "username" => username,
        "credential" => password
      }
    ]
  end
end
