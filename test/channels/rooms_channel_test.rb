require "test_helper"

class RoomsChannelTest < ActionCable::Channel::TestCase
  tests RoomsChannel

  class InMemoryRedis
    def initialize(initial_values = {})
      @values = initial_values.transform_values(&:to_s)
    end

    def exists?(key)
      @values.key?(key)
    end

    def incr(key)
      value = @values.fetch(key, "0").to_i + 1
      @values[key] = value.to_s
      value
    end

    def decr(key)
      value = @values.fetch(key, "0").to_i - 1
      @values[key] = value.to_s
      value
    end

    def get(key)
      @values[key]
    end
  end

  setup do
    stub_connection token_id: SecureRandom.uuid
  end

  test "relays signaling payload without peer awareness" do
    room_id = "room-123"
    redis = InMemoryRedis.new(
      "room:#{room_id}" => "active",
      "room:#{room_id}:count" => "0"
    )

    with_stubbed_redis(redis) do
      subscribe room_id: room_id

      assert subscription.confirmed?
      assert_has_stream "rooms:#{room_id}"

      init_payload = transmissions.last.deep_symbolize_keys
      connection_id = init_payload.fetch(:connection_id)
      signal_data = { "sdp" => "offer", "type" => "offer" }

      assert_broadcast_on(
        "rooms:#{room_id}",
        { type: "signal", data: signal_data, connection_id: connection_id }
      ) do
        perform :send_signal, { "data" => signal_data }
      end
    end
  end

  test "rejects subscription when room does not exist" do
    redis = InMemoryRedis.new

    with_stubbed_redis(redis) do
      subscribe room_id: "missing-room"

      assert subscription.rejected?
    end
  end

  test "rejects a third peer and rolls count back" do
    room_id = "room-full"
    redis = InMemoryRedis.new(
      "room:#{room_id}" => "active",
      "room:#{room_id}:count" => "2"
    )

    with_stubbed_redis(redis) do
      subscribe room_id: room_id

      assert subscription.rejected?
      assert_equal "2", redis.get("room:#{room_id}:count")
    end
  end

  test "handles malformed signal payload without crashing" do
    room_id = "room-malformed"
    redis = InMemoryRedis.new(
      "room:#{room_id}" => "active",
      "room:#{room_id}:count" => "0"
    )

    with_stubbed_redis(redis) do
      subscribe room_id: room_id

      assert subscription.confirmed?

      init_payload = transmissions.last.deep_symbolize_keys
      connection_id = init_payload.fetch(:connection_id)

      assert_broadcast_on(
        "rooms:#{room_id}",
        { type: "signal", data: nil, connection_id: connection_id }
      ) do
        perform :send_signal, {}
      end
    end
  end

  private

  def with_stubbed_redis(fake_redis)
    original_redis = REDIS
    Object.send(:remove_const, :REDIS)
    Object.const_set(:REDIS, fake_redis)
    yield
  ensure
    Object.send(:remove_const, :REDIS)
    Object.const_set(:REDIS, original_redis)
  end
end
