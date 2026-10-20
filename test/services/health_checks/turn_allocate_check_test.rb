# frozen_string_literal: true

require "test_helper"
require_relative "../../support/tls_test_server"

class HealthChecks::TurnAllocateCheckTest < ActiveSupport::TestCase
  include TlsTestServer

  Stun = HealthChecks::Stun
  SECRET = "turn-test-secret"
  REALM = "nullroom.io"

  setup do
    ENV["COTURN_SECRET"] = SECRET
    @cert, @key = issue_cert(hostname: "turn.nullroom.test", expires_in: 30 * DAY)
  end

  teardown do
    ENV.delete("COTURN_SECRET")
  end

  test "ok when the authenticated allocation succeeds and is released" do
    requests = []
    result = run_against(fake_turn_server(requests: requests))

    assert_equal "ok", result.status
    assert_equal [ Stun::ALLOCATE_REQUEST, Stun::ALLOCATE_REQUEST, Stun::REFRESH_REQUEST ], requests.map(&:type)
    assert_equal [ 0 ].pack("N"), requests.last[Stun::ATTR_LIFETIME]
  end

  test "auth_failed when coturn and the app disagree on the shared secret" do
    result = run_against(fake_turn_server(secret: "rotated-on-coturn-only"))

    assert_equal "down", result.status
    assert_equal "auth_failed", result.reason
  end

  test "quota_reached when coturn refuses the allocation" do
    assert_equal "quota_reached", run_against(fake_turn_server(allocate_error: 486)).reason
  end

  test "credentials_unavailable without COTURN_SECRET" do
    ENV.delete("COTURN_SECRET")

    assert_equal "credentials_unavailable", HealthChecks::TurnAllocateCheck.new(host: "127.0.0.1", port: 9, server_name: "x").run.reason
  end

  private

  def run_against(handler)
    with_tls_server(cert: @cert, key: @key, handler: handler) do |port|
      HealthChecks::TurnAllocateCheck.new(host: "127.0.0.1", port: port, server_name: "turn.nullroom.test").run
    end
  end

  # Mimics coturn's long-term credential flow with the TURN REST shared secret:
  # 401 challenge, then MESSAGE-INTEGRITY verified with the HMAC-derived password.
  def fake_turn_server(secret: SECRET, allocate_error: nil, requests: [])
    lambda do |connection|
      while (header = connection.read(Stun::HEADER_SIZE))
        data = header + connection.read(Stun.body_length(header)).to_s
        request = Stun.decode(data)
        requests << request
        connection.write(respond(request, data, secret, allocate_error))
      end
    end
  end

  def respond(request, data, secret, allocate_error)
    username = request[Stun::ATTR_USERNAME]
    return error(request, 401, [ [ Stun::ATTR_REALM, REALM ], [ Stun::ATTR_NONCE, "nonce-1" ] ]) unless username

    password = Base64.strict_encode64(OpenSSL::HMAC.digest("SHA1", secret, username))
    key = Stun.long_term_key(username, REALM, password)
    valid = OpenSSL::HMAC.digest("SHA1", key, data.byteslice(0, data.bytesize - 24)) == data.byteslice(-20, 20)
    return error(request, 401) unless valid
    return error(request, allocate_error) if allocate_error && request.type == Stun::ALLOCATE_REQUEST

    attributes = request.type == Stun::ALLOCATE_REQUEST ? [ [ Stun::ATTR_XOR_RELAYED_ADDRESS, "\x00".b * 8 ] ] : []
    Stun.encode(request.type | 0x0100, request.transaction_id, attributes)
  end

  def error(request, code, attributes = [])
    value = [ 0, 0, code / 100, code % 100 ].pack("C4")
    Stun.encode(request.type | 0x0110, request.transaction_id, [ [ Stun::ATTR_ERROR_CODE, value ], *attributes ])
  end
end
