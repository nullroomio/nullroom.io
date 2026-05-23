# frozen_string_literal: true

require "test_helper"

class RoomsControllerTest < ActionDispatch::IntegrationTest
  parallelize(workers: 1)

  setup do
    ENV["COTURN_SECRET"] = "test-secret"
  end

  teardown do
    ENV.delete("COTURN_SECRET")
  end

  # --- Provider dispatch (coturn, default) ---

  test "create returns coturn ICE servers when provider is coturn" do
    with_stubbed_redis do
      post "/rooms", as: :json

      assert_response :success
      servers = response.parsed_body["turn_servers"]

      assert_equal 2, servers.length
      assert_includes servers[0]["urls"].first, "stun:"
      assert_includes servers[1]["urls"].first, "turns:"
      assert_includes servers[1]["urls"].first, ":443"
      assert servers[1]["username"].present?
      assert servers[1]["credential"].present?
    end
  end

  test "show renders coturn ICE servers in data attribute" do
    with_stubbed_redis do |redis|
      room_id = SecureRandom.uuid
      redis.setex("room:#{room_id}", 900, "active")
      redis.setex("room:#{room_id}:count", 960, "0")

      get "/rooms/#{room_id}"

      assert_response :success
      assert_includes response.body, "turns:turn.nullroom.io:443"
    end
  end

  # --- Provider dispatch (cloudflare) ---

  test "create uses CloudflareTurnService when provider is cloudflare" do
    with_stubbed_redis do
      with_turn_provider("cloudflare") do
        with_stubbed_cloudflare_turn do
          post "/rooms", as: :json

          assert_response :success
          servers = response.parsed_body["turn_servers"]
          assert_equal [ { "urls" => [ "turn:cf.example.com:443" ] } ], servers
        end
      end
    end
  end

  # --- Fallback on failure ---

  test "create returns empty turn_servers when coturn service raises" do
    with_stubbed_redis do
      ENV.delete("COTURN_SECRET")

      post "/rooms", as: :json

      assert_response :success
      assert_equal [], response.parsed_body["turn_servers"]
    end
  end

  test "show renders empty ICE servers when coturn service raises" do
    with_stubbed_redis do |redis|
      room_id = SecureRandom.uuid
      redis.setex("room:#{room_id}", 900, "active")
      redis.setex("room:#{room_id}:count", 960, "0")
      ENV.delete("COTURN_SECRET")

      get "/rooms/#{room_id}"

      assert_response :success
      assert_includes response.body, 'data-room-turn-servers-value="[]"'
    end
  end

  private

  def with_stubbed_redis
    fake = FakeRedis.new
    original = REDIS
    Object.send(:remove_const, :REDIS)
    Object.const_set(:REDIS, fake)
    yield fake
  ensure
    Object.send(:remove_const, :REDIS)
    Object.const_set(:REDIS, original)
  end

  def with_turn_provider(provider)
    original = Nullroom::Config::TURN_PROVIDER
    Nullroom::Config.send(:remove_const, :TURN_PROVIDER)
    Nullroom::Config.const_set(:TURN_PROVIDER, provider)
    yield
  ensure
    Nullroom::Config.send(:remove_const, :TURN_PROVIDER)
    Nullroom::Config.const_set(:TURN_PROVIDER, original)
  end

  def with_stubbed_cloudflare_turn
    fake_service = Class.new do
      def generate_ice_servers
        [ { "urls" => [ "turn:cf.example.com:443" ] } ]
      end
    end.new

    original_new = CloudflareTurnService.method(:new)
    CloudflareTurnService.singleton_class.define_method(:new) { fake_service }
    yield
  ensure
    CloudflareTurnService.singleton_class.define_method(:new) do |*args, **kwargs, &block|
      original_new.call(*args, **kwargs, &block)
    end
  end

  class FakeRedis
    def initialize
      @store = {}
    end

    def setex(key, _ttl, value)
      @store[key] = value
      "OK"
    end

    def exists?(key)
      @store.key?(key)
    end

    def del(key)
      @store.delete(key) ? 1 : 0
    end
  end
end
