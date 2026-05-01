require "test_helper"

class HandshakesControllerTest < ActionDispatch::IntegrationTest
  parallelize(workers: 1)

  test "create stores blob and returns 201" do
    with_stubbed_redis do
      identifier = "a" * 64
      blob = "dGVzdGJsb2I="

      post "/handshakes/#{identifier}",
        params: { blob: blob },
        as: :json

      assert_response :created
    end
  end

  test "show returns blob and deletes it (one-time read)" do
    with_stubbed_redis do
      identifier = "b" * 64
      blob = "ZW5jcnlwdGVkX2RhdGE="

      post "/handshakes/#{identifier}",
        params: { blob: blob },
        as: :json
      assert_response :created

      # First read succeeds
      get "/handshakes/#{identifier}", as: :json
      assert_response :success
      assert_equal blob, response.parsed_body.fetch("blob")

      # Second read returns 404 (deleted on first read)
      get "/handshakes/#{identifier}", as: :json
      assert_response :not_found
    end
  end

  test "create rejects invalid identifier (too short)" do
    with_stubbed_redis do
      post "/handshakes/tooshort",
        params: { blob: "dGVzdA==" },
        as: :json

      assert_response :unprocessable_entity
    end
  end

  test "create rejects invalid identifier (non-hex characters)" do
    with_stubbed_redis do
      identifier = "g" * 64

      post "/handshakes/#{identifier}",
        params: { blob: "dGVzdA==" },
        as: :json

      assert_response :unprocessable_entity
    end
  end

  test "create rejects oversized blob" do
    with_stubbed_redis do
      identifier = "c" * 64
      oversized_blob = "x" * 2049

      post "/handshakes/#{identifier}",
        params: { blob: oversized_blob },
        as: :json

      assert_response :unprocessable_entity
    end
  end

  test "create rejects missing blob" do
    with_stubbed_redis do
      identifier = "d" * 64

      post "/handshakes/#{identifier}",
        params: {},
        as: :json

      assert_response :unprocessable_entity
    end
  end

  test "create rejects duplicate identifier" do
    with_stubbed_redis do
      identifier = "e" * 64
      blob = "Zmlyc3Q="

      post "/handshakes/#{identifier}",
        params: { blob: blob },
        as: :json
      assert_response :created

      post "/handshakes/#{identifier}",
        params: { blob: "c2Vjb25k" },
        as: :json
      assert_response :conflict
    end
  end

  test "show returns 404 for nonexistent identifier" do
    with_stubbed_redis do
      identifier = "f" * 64

      get "/handshakes/#{identifier}", as: :json
      assert_response :not_found
    end
  end

  private

  def with_stubbed_redis
    original = REDIS
    Object.send(:remove_const, :REDIS)
    Object.const_set(:REDIS, FakeRedis.new)
    yield
  ensure
    Object.send(:remove_const, :REDIS)
    Object.const_set(:REDIS, original)
  end

  class FakeRedis
    def initialize
      @store = {}
    end

    def setex(key, _ttl, value)
      @store[key] = value
      "OK"
    end

    def get(key)
      @store[key]
    end

    def exists?(key)
      @store.key?(key)
    end

    def del(key)
      @store.delete(key) ? 1 : 0
    end
  end
end
