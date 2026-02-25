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

    def del(*keys)
      keys.sum { |key| @values.delete(key) ? 1 : 0 }
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

  test "destroys room keys when a peer unsubscribes and flag is enabled" do
    room_id = "room-destroy"
    redis = InMemoryRedis.new(
      "room:#{room_id}" => "active",
      "room:#{room_id}:count" => "1"
    )

    # Explicitly enable destroy behavior
    original_value = Nullroom::Config::DESTROY_ROOM_ON_PEER_LEAVE
    silence_warnings do
      Nullroom::Config.const_set(:DESTROY_ROOM_ON_PEER_LEAVE, true)
    end

    with_stubbed_redis(redis) do
      subscribe room_id: room_id

      assert subscription.confirmed?

      init_payload = transmissions.last.deep_symbolize_keys
      connection_id = init_payload.fetch(:connection_id)

      assert_broadcast_on(
        "rooms:#{room_id}",
        { type: "peer_left", connection_id: connection_id }
      ) do
        unsubscribe
      end

      assert_not redis.exists?("room:#{room_id}")
      assert_not redis.exists?("room:#{room_id}:count")
    end
  ensure
    # Restore original value
    silence_warnings do
      Nullroom::Config.const_set(:DESTROY_ROOM_ON_PEER_LEAVE, original_value)
    end
  end

  test "keeps room keys when a peer unsubscribes and flag is disabled" do
    room_id = "room-preserve"
    redis = InMemoryRedis.new(
      "room:#{room_id}" => "active",
      "room:#{room_id}:count" => "1"
    )

    # Temporarily disable destroy behavior
    original_value = Nullroom::Config::DESTROY_ROOM_ON_PEER_LEAVE
    silence_warnings do
      Nullroom::Config.const_set(:DESTROY_ROOM_ON_PEER_LEAVE, false)
    end

    with_stubbed_redis(redis) do
      subscribe room_id: room_id

      assert subscription.confirmed?

      init_payload = transmissions.last.deep_symbolize_keys
      connection_id = init_payload.fetch(:connection_id)

      assert_broadcast_on(
        "rooms:#{room_id}",
        { type: "peer_left", connection_id: connection_id }
      ) do
        unsubscribe
      end

      # Room should still exist when flag is disabled
      assert redis.exists?("room:#{room_id}")
      assert redis.exists?("room:#{room_id}:count")
      # Count was incremented to 2 on subscribe, then decremented to 1 on unsubscribe
      assert_equal "1", redis.get("room:#{room_id}:count")
    end
  ensure
    # Restore original value
    silence_warnings do
      Nullroom::Config.const_set(:DESTROY_ROOM_ON_PEER_LEAVE, original_value)
    end
  end

  test "init message includes file_sharing flag set to true" do
    room_id = "room-file-sharing"
    redis = InMemoryRedis.new(
      "room:#{room_id}" => "active",
      "room:#{room_id}:count" => "0"
    )

    with_stubbed_redis(redis) do
      subscribe room_id: room_id

      assert subscription.confirmed?

      init_payload = transmissions.last.deep_symbolize_keys
      assert_equal "init", init_payload[:type]
      assert init_payload[:file_sharing], "expected file_sharing to be true in the init message"
    end
  end

  test "initiate_file_transfer authorises and transmits authorized for files within the 25 MB limit" do
    room_id = "room-file-ok"
    redis = InMemoryRedis.new(
      "room:#{room_id}" => "active",
      "room:#{room_id}:count" => "0"
    )

    with_stubbed_redis(redis) do
      subscribe room_id: room_id
      assert subscription.confirmed?

      perform :initiate_file_transfer, { "metadata" => { "file_name" => "photo.jpg", "file_size" => 10_000_000 } }

      response = transmissions.last.deep_symbolize_keys
      assert_equal "file_transfer_authorized", response[:type]
    end
  end

  test "initiate_file_transfer rejects and transmits error for files exceeding the 25 MB limit" do
    room_id = "room-file-too-large"
    redis = InMemoryRedis.new(
      "room:#{room_id}" => "active",
      "room:#{room_id}:count" => "0"
    )

    with_stubbed_redis(redis) do
      subscribe room_id: room_id
      assert subscription.confirmed?

      perform :initiate_file_transfer, { "metadata" => { "file_name" => "huge.zip", "file_size" => 30_000_000 } }

      response = transmissions.last.deep_symbolize_keys
      assert_equal "file_transfer_error", response[:type]
      assert_includes response[:error], "24 MB"
    end
  end

  test "destroys room keys without broadcasting when last peer unsubscribes" do
    room_id = "room-last-peer"
    redis = InMemoryRedis.new(
      "room:#{room_id}" => "active",
      "room:#{room_id}:count" => "0"
    )

    # Explicitly enable destroy behavior
    original_value = Nullroom::Config::DESTROY_ROOM_ON_PEER_LEAVE
    silence_warnings do
      Nullroom::Config.const_set(:DESTROY_ROOM_ON_PEER_LEAVE, true)
    end

    with_stubbed_redis(redis) do
      subscribe room_id: room_id

      assert subscription.confirmed?

      assert_no_broadcasts("rooms:#{room_id}") do
        unsubscribe
      end

      assert_not redis.exists?("room:#{room_id}")
      assert_not redis.exists?("room:#{room_id}:count")
    end
  ensure
    # Restore original value
    silence_warnings do
      Nullroom::Config.const_set(:DESTROY_ROOM_ON_PEER_LEAVE, original_value)
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
