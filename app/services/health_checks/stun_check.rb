# frozen_string_literal: true

require "io/wait"
require "socket"

module HealthChecks
  # Sends a STUN Binding request over UDP and expects a Binding success with a
  # mapped address — a real protocol exchange, not just an open-port probe.
  class StunCheck < Check
    def initialize(host:, port: 3478)
      @host = host
      @port = port
    end

    def timeout
      3
    end

    def call
      transaction_id = Stun.transaction_id
      address = Addrinfo.udp(@host, @port)
      socket = UDPSocket.new(address.afamily)
      socket.connect(address.ip_address, address.ip_port)
      socket.send(Stun.encode(Stun::BINDING_REQUEST, transaction_id), 0)

      return Result.down("timeout") unless socket.wait_readable(timeout - 1)

      response = Stun.decode(socket.recv(2048))
      return Result.down("bad_response") unless response.type == Stun::BINDING_SUCCESS &&
        response.transaction_id == transaction_id && response[Stun::ATTR_XOR_MAPPED_ADDRESS]

      Result.ok
    rescue ArgumentError
      Result.down("bad_response")
    ensure
      socket&.close
    end
  end
end
