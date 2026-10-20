# frozen_string_literal: true

require "test_helper"

class HealthChecks::TorCheckTest < ActiveSupport::TestCase
  test "ok when the proxy accepts a no-auth SOCKS5 greeting" do
    with_tcp_server([ 5, 0 ].pack("C2")) do |port|
      assert_equal "ok", HealthChecks::TorCheck.new(host: "127.0.0.1", port: port).run.status
    end
  end

  test "down when the proxy refuses every auth method" do
    with_tcp_server([ 5, 0xFF ].pack("C2")) do |port|
      assert_equal "bad_response", HealthChecks::TorCheck.new(host: "127.0.0.1", port: port).run.reason
    end
  end

  private

  def with_tcp_server(reply)
    server = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new do
      client = server.accept
      client.read(3)
      client.write(reply)
      client.close
    end

    yield server.addr[1]
  ensure
    thread&.kill
    server&.close
  end
end
