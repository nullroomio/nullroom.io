require "test_helper"

class RackAttackTest < ActionDispatch::IntegrationTest
  parallelize(workers: 1)

  setup do
    Rack::Attack.cache.store.clear
  end

  teardown do
    Rack::Attack.cache.store.clear
  end

  test "limits room creation to five requests per minute per ip" do
    with_stubbed_redis do
      with_stubbed_turn_service do
        5.times do
          post "/rooms", as: :json
          assert_response :success
        end

        post "/rooms", as: :json

        assert_response :too_many_requests
        assert_equal "Rate limit exceeded. Try again later.", response.parsed_body.fetch("error")
        assert_equal "60", response.headers["Retry-After"]
      end
    end
  end

  test "limits blind token session creation to three requests per minute per ip" do
    with_stubbed_redis do
      with_stubbed_monero_service do
        3.times do
          post "/blind_tokens/session", as: :json
          assert_response :success
        end

        post "/blind_tokens/session", as: :json

        assert_response :too_many_requests
        assert_equal "Rate limit exceeded. Try again later.", response.parsed_body.fetch("error")
        assert_equal "60", response.headers["Retry-After"]
      end
    end
  end

  test "limits landing page requests to sixty per minute per ip" do
    60.times do
      get "/"
      assert_response :success
    end

    get "/"

    assert_response :too_many_requests
    assert_equal "Rate limit exceeded. Try again later.", response.parsed_body.fetch("error")
    assert_equal "application/json", response.headers["Content-Type"]
    assert_equal "60", response.headers["Retry-After"]
  end

  test "limits health checks to five requests per minute per ip" do
    with_stubbed_redis do
      5.times do
        get "/up", as: :json
        assert_response :success
      end

      get "/up", as: :json

      assert_response :too_many_requests
      assert_equal "Rate limit exceeded. Try again later.", response.parsed_body.fetch("error")
      assert_equal "application/json", response.headers["Content-Type"]
      assert_equal "60", response.headers["Retry-After"]
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

  def with_stubbed_turn_service
    fake_service = Class.new do
      def generate_ice_servers
        []
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

  def with_stubbed_monero_service
    fake_service = Class.new do
      def create_subaddress(account_index: 0)
        _ = account_index
        { subaddress: "84stub", address_index: 7 }
      end
    end.new

    original_new = MoneroPaymentService.method(:new)
    MoneroPaymentService.singleton_class.define_method(:new) { fake_service }
    yield
  ensure
    MoneroPaymentService.singleton_class.define_method(:new) do |*args, **kwargs, &block|
      original_new.call(*args, **kwargs, &block)
    end
  end

  class FakeRedis
    def initialize
      @store = {}
    end

    def set(key, value, ex: nil)
      _ = ex
      @store[key] = value
      "OK"
    end

    def setex(key, _ttl, value)
      @store[key] = value
      "OK"
    end

    def del(key)
      @store.delete(key) ? 1 : 0
    end
  end
end
