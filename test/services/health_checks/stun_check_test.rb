# frozen_string_literal: true

require "test_helper"

class HealthChecks::StunCheckTest < ActiveSupport::TestCase
  Stun = HealthChecks::Stun

  test "ok when the server answers a binding request with a mapped address" do
    with_udp_server(->(request) {
      Stun.encode(Stun::BINDING_SUCCESS, request.transaction_id, [ [ Stun::ATTR_XOR_MAPPED_ADDRESS, "\x00\x01\x00\x00\x00\x00\x00\x00".b ] ])
    }) do |port|
      assert_equal "ok", HealthChecks::StunCheck.new(host: "127.0.0.1", port: port).run.status
    end
  end

  test "down when the response belongs to another transaction" do
    with_udp_server(->(_request) {
      Stun.encode(Stun::BINDING_SUCCESS, Stun.transaction_id, [ [ Stun::ATTR_XOR_MAPPED_ADDRESS, "\x00".b * 8 ] ])
    }) do |port|
      result = HealthChecks::StunCheck.new(host: "127.0.0.1", port: port).run

      assert_equal "down", result.status
      assert_equal "bad_response", result.reason
    end
  end

  test "down when the server answers with garbage" do
    with_udp_server(->(_request) { "not stun" }) do |port|
      assert_equal "bad_response", HealthChecks::StunCheck.new(host: "127.0.0.1", port: port).run.reason
    end
  end

  private

  def with_udp_server(responder)
    socket = UDPSocket.new
    socket.bind("127.0.0.1", 0)
    thread = Thread.new do
      data, (_, port, host) = socket.recvfrom(2048)
      socket.send(responder.call(Stun.decode(data)), 0, host, port)
    end

    yield socket.addr[1]
  ensure
    thread&.kill
    socket&.close
  end
end
