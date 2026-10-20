# frozen_string_literal: true

require "socket"

module HealthChecks
  # Monero RPC traffic leaves through the Tor SOCKS proxy; checks that it
  # accepts a SOCKS5 greeting (no-auth).
  class TorCheck < Check
    SOCKS5_GREETING = [ 5, 1, 0 ].pack("C3")
    SOCKS5_NO_AUTH = [ 5, 0 ].pack("C2")

    def initialize(host:, port:)
      @host = host
      @port = port
    end

    def call
      Socket.tcp(@host, @port, connect_timeout: timeout) do |socket|
        socket.write(SOCKS5_GREETING)
        socket.read(2) == SOCKS5_NO_AUTH ? Result.ok : Result.down("bad_response")
      end
    end
  end
end
