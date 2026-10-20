# frozen_string_literal: true

require "openssl"
require "socket"

module HealthChecks
  # Performs a real TURN allocation over TURNS (TLS/443) with ephemeral
  # credentials from CoturnService — the same path a browser takes when it
  # needs the relay. Catches a COTURN_SECRET mismatch between the app and
  # coturn, quota exhaustion, or a broken relay that a port probe can't see.
  #
  # Certificate validity is TlsCertCheck's job, so this check doesn't verify
  # the chain and the two failures stay distinguishable on the status page.
  class TurnAllocateCheck < Check
    REQUESTED_TRANSPORT_UDP = [ 17, 0, 0, 0 ].pack("C4")

    ERROR_REASONS = {
      401 => "auth_failed",
      486 => "quota_reached",
      508 => "insufficient_capacity"
    }.freeze

    def initialize(host:, server_name:, port: 443)
      @host = host
      @port = port
      @server_name = server_name
    end

    def call
      username, password = credentials
      return Result.down("credentials_unavailable") unless username

      with_tls_socket do |socket|
        # Unauthenticated Allocate is answered with 401 + realm + nonce.
        challenge = exchange(socket, allocate_request)
        realm = challenge[Stun::ATTR_REALM]
        nonce = challenge[Stun::ATTR_NONCE]
        return Result.down("allocate_failed") unless challenge.error_code == 401 && realm && nonce

        key = Stun.long_term_key(username, realm, password)
        auth = [ [ Stun::ATTR_USERNAME, username ], [ Stun::ATTR_REALM, realm ], [ Stun::ATTR_NONCE, nonce ] ]

        response = exchange(socket, allocate_request(auth, key))
        unless response.type == Stun::ALLOCATE_SUCCESS && response[Stun::ATTR_XOR_RELAYED_ADDRESS]
          return Result.down(ERROR_REASONS.fetch(response.error_code, "allocate_failed"))
        end

        release(socket, auth, key)
        Result.ok
      end
    rescue ArgumentError
      Result.down("bad_response")
    end

    private

    def credentials
      turns = CoturnService.new.generate_ice_servers(ttl: 5 * 60).find { |server| server["username"] }
      [ turns["username"], turns["credential"] ]
    rescue KeyError
      nil
    end

    def allocate_request(auth = [], key = nil)
      attributes = [ [ Stun::ATTR_REQUESTED_TRANSPORT, REQUESTED_TRANSPORT_UDP ], *auth ]
      Stun.encode(Stun::ALLOCATE_REQUEST, Stun.transaction_id, attributes, integrity_key: key)
    end

    # Refresh with LIFETIME 0 frees the allocation immediately, so health checks
    # never hold relay capacity. Best effort: it expires on its own otherwise.
    def release(socket, auth, key)
      attributes = [ [ Stun::ATTR_LIFETIME, [ 0 ].pack("N") ], *auth ]
      exchange(socket, Stun.encode(Stun::REFRESH_REQUEST, Stun.transaction_id, attributes, integrity_key: key))
    rescue StandardError
      nil
    end

    # STUN over a stream transport: messages are sent back to back, framed by
    # the length field in each header.
    def exchange(socket, request)
      socket.write(request)
      header = socket.read(Stun::HEADER_SIZE).to_s
      response = Stun.decode(header + socket.read(Stun.body_length(header)).to_s)
      raise ArgumentError, "transaction mismatch" unless response.transaction_id == request.byteslice(8, 12)

      response
    end

    def with_tls_socket
      Socket.tcp(@host, @port, connect_timeout: timeout) do |tcp|
        context = OpenSSL::SSL::SSLContext.new
        context.verify_mode = OpenSSL::SSL::VERIFY_NONE
        ssl = OpenSSL::SSL::SSLSocket.new(tcp, context)
        ssl.hostname = @server_name
        ssl.connect

        yield ssl
      ensure
        ssl&.close
      end
    end
  end
end
