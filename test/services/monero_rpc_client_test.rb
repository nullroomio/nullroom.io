require "test_helper"

class MoneroRpcClientTest < ActiveSupport::TestCase
  test "call returns parsed result on successful response" do
    client = new_client
    client.digest_response = http_ok({ result: { "address" => "84abc" } })

    result = client.call("create_address", account_index: 0)
    assert_equal({ "address" => "84abc" }, result)
  end

  test "call uses curl fallback when digest request returns 401" do
    client = new_client
    client.digest_response = Net::HTTPUnauthorized.new("1.1", "401", "Unauthorized")
    client.fallback_response = http_ok({ result: { "ok" => true } })

    result = client.call("incoming_transfers", transfer_type: "available")
    assert_equal({ "ok" => true }, result)
    assert_equal true, client.fallback_called
  end

  test "call raises for non-success http response" do
    client = new_client
    response = Net::HTTPBadGateway.new("1.1", "502", "Bad Gateway")
    response.instance_variable_set(:@read, true)
    response.body = "gateway error"
    client.digest_response = response

    error = assert_raises(RuntimeError) { client.call("incoming_transfers") }
    assert_includes error.message, "Monero RPC HTTP error 502"
  end

  test "call raises for rpc-level error payload" do
    client = new_client
    client.digest_response = http_ok({ error: { code: -1, message: "boom" } })

    error = assert_raises(RuntimeError) { client.call("incoming_transfers") }
    assert_includes error.message, "Monero RPC error"
  end

  private

  def new_client
    TestMoneroRpcClient.new(
      url: "http://example.onion:18083/json_rpc",
      username: "rpc-user",
      password: "rpc-pass",
      tor_socks_host: "127.0.0.1",
      tor_socks_port: 9050
    )
  end

  def http_ok(payload_hash)
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response.instance_variable_set(:@read, true)
    response.body = JSON.generate(payload_hash)
    response
  end

  class TestMoneroRpcClient < MoneroRpcClient
    attr_accessor :digest_response, :fallback_response, :fallback_called

    private

    def digest_authenticated_post(uri:, body:)
      digest_response
    end

    def curl_digest_fallback(uri:, body:)
      self.fallback_called = true
      fallback_response
    end
  end
end
