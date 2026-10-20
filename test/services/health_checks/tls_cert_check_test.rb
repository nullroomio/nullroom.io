# frozen_string_literal: true

require "test_helper"
require_relative "../../support/tls_test_server"

class HealthChecks::TlsCertCheckTest < ActiveSupport::TestCase
  include TlsTestServer

  HOST = "turn.nullroom.test"

  setup do
    @ca = generate_ca
  end

  test "ok with days left when the cert is valid and far from expiry" do
    result = check_with(expires_in: 80 * DAY)

    assert_equal "ok", result.status
    assert_equal 79, result.details[:days_left]
    assert_equal (Time.now + 80 * DAY).utc.to_date.iso8601, result.details[:expires_on]
  end

  test "degraded when renewal should already have happened" do
    result = check_with(expires_in: 15 * DAY)

    assert_equal "degraded", result.status
    assert_equal "cert_expiring", result.reason
  end

  test "down within a week of expiry" do
    result = check_with(expires_in: 3 * DAY)

    assert_equal "down", result.status
    assert_equal "cert_expiring", result.reason
  end

  test "down when the served cert has expired" do
    result = check_with(expires_in: -2 * DAY)

    assert_equal "down", result.status
    assert_equal "cert_expired", result.reason
    assert_predicate result.details[:days_left], :negative?
  end

  test "down when the cert is for another hostname" do
    result = check_with(expires_in: 80 * DAY, hostname: "other.nullroom.test")

    assert_equal "cert_hostname_mismatch", result.reason
  end

  test "down when the chain is not trusted" do
    result = check_with(expires_in: 80 * DAY, store: cert_store)

    assert_equal "cert_untrusted", result.reason
  end

  test "down when nothing is listening" do
    port = TCPServer.open("127.0.0.1", 0) { |server| server.addr[1] }
    result = HealthChecks::TlsCertCheck.new(host: "127.0.0.1", port: port, server_name: HOST).run

    assert_equal "down", result.status
    assert_equal "connect_failed", result.reason
  end

  private

  def check_with(expires_in:, hostname: HOST, store: cert_store(@ca.first))
    cert, key = issue_cert(hostname: hostname, expires_in: expires_in, ca: @ca)

    with_tls_server(cert: cert, key: key) do |port|
      HealthChecks::TlsCertCheck.new(host: "127.0.0.1", port: port, server_name: HOST, cert_store: store).run
    end
  end
end
