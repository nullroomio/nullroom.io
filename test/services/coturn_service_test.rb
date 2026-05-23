# frozen_string_literal: true

require "test_helper"

class CoturnServiceTest < ActiveSupport::TestCase
  TEST_SECRET = "test-shared-secret"

  setup do
    ENV["COTURN_SECRET"] = TEST_SECRET
  end

  teardown do
    ENV.delete("COTURN_SECRET")
  end

  test "generate_ice_servers returns stun and turns entries" do
    servers = CoturnService.new.generate_ice_servers

    assert_equal 2, servers.length

    stun_entry = servers[0]
    turns_entry = servers[1]

    assert_equal [ "stun:turn.nullroom.io:3478" ], stun_entry["urls"]
    assert_nil stun_entry["username"]
    assert_nil stun_entry["credential"]

    assert_equal [ "turns:turn.nullroom.io:443?transport=tcp" ], turns_entry["urls"]
    assert turns_entry["username"].present?
    assert turns_entry["credential"].present?
  end

  test "username is a future unix timestamp" do
    freeze_time do
      servers = CoturnService.new.generate_ice_servers(ttl: 3600)
      username = servers[1]["username"]

      expected_expiry = Time.now.to_i + 3600
      assert_equal expected_expiry.to_s, username
    end
  end

  test "credential is a valid HMAC-SHA1 of the username" do
    freeze_time do
      servers = CoturnService.new.generate_ice_servers

      username = servers[1]["username"]
      credential = servers[1]["credential"]

      expected = Base64.strict_encode64(
        OpenSSL::HMAC.digest("SHA1", TEST_SECRET, username)
      )

      assert_equal expected, credential
    end
  end

  test "raises when COTURN_SECRET is not set" do
    ENV.delete("COTURN_SECRET")

    assert_raises(KeyError) { CoturnService.new }
  end
end
