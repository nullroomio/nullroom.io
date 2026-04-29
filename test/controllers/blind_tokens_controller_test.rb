require "test_helper"

class BlindTokensControllerTest < ActionDispatch::IntegrationTest
  parallelize(workers: 1)

  test "create payment session returns expected payload" do
    with_stubbed_redis do
      service = FakeMoneroService.new(
        create_subaddress_result: { subaddress: "84sub", address_index: 3 }
      )

      with_stubbed_monero_service(service) do
        post "/blind_tokens/session", as: :json
      end

      assert_response :success
      body = response.parsed_body

      assert_equal "84sub", body.fetch("subaddress")
      assert_equal "waiting", body.fetch("status")
      assert_equal Nullroom::Config::DONATION_AMOUNT_PICONERO, body.fetch("amount_piconero")
      assert_equal Nullroom::Config::DONATION_CONFIRMATIONS_REQUIRED, body.fetch("required_confirmations")
      assert body.fetch("payment_session_id").present?
    end
  end

  test "status endpoint transitions waiting detected confirming ready" do
    with_stubbed_redis do
      amount = Nullroom::Config::DONATION_AMOUNT_PICONERO
      required_confirmations = Nullroom::Config::DONATION_CONFIRMATIONS_REQUIRED

      statuses = [
        { total_received_piconero: 0, pending_amount_piconero: amount - 1, max_confirmations: 0, paid: false },
        { total_received_piconero: 0, pending_amount_piconero: amount, max_confirmations: 0, paid: false },
        { total_received_piconero: amount, pending_amount_piconero: 0, max_confirmations: required_confirmations - 1, paid: true },
        { total_received_piconero: amount, pending_amount_piconero: 0, max_confirmations: required_confirmations, paid: true }
      ]

      service = FakeMoneroService.new(
        create_subaddress_result: { subaddress: "84status", address_index: 5 },
        check_status_results: statuses
      )

      with_stubbed_monero_service(service) do
        post "/blind_tokens/session", as: :json
        assert_response :success
        session_id = response.parsed_body.fetch("payment_session_id")

        get "/blind_tokens/status", params: { payment_session_id: session_id }, as: :json
        assert_response :success
        assert_equal "waiting", response.parsed_body.fetch("status")

        get "/blind_tokens/status", params: { payment_session_id: session_id }, as: :json
        assert_response :success
        assert_equal "detected", response.parsed_body.fetch("status")

        get "/blind_tokens/status", params: { payment_session_id: session_id }, as: :json
        assert_response :success
        assert_equal "confirming", response.parsed_body.fetch("status")

        get "/blind_tokens/status", params: { payment_session_id: session_id }, as: :json
        assert_response :success
        assert_equal "ready", response.parsed_body.fetch("status")
      end
    end
  end

  test "sign returns payment_not_ready when status is not ready" do
    with_stubbed_redis do
      service = FakeMoneroService.new(
        create_subaddress_result: { subaddress: "84guard", address_index: 9 },
        check_status_results: [
          { total_received_piconero: 0, pending_amount_piconero: 0, max_confirmations: 0, paid: false }
        ]
      )

      with_stubbed_monero_service(service) do
        post "/blind_tokens/session", as: :json
        assert_response :success
        session_id = response.parsed_body.fetch("payment_session_id")

        post "/blind_tokens/sign",
          params: {
            payment_session_id: session_id,
            blinded_message: "deadbeef"
          },
          as: :json

        assert_response :unprocessable_entity
        assert_equal "payment_not_ready", response.parsed_body.fetch("error")
        assert_equal "waiting", response.parsed_body.fetch("status")
      end
    end
  end

  test "sign rejects second claim with different blinded message" do
    with_stubbed_redis do
      ready_status = {
        total_received_piconero: Nullroom::Config::DONATION_AMOUNT_PICONERO,
        pending_amount_piconero: 0,
        max_confirmations: Nullroom::Config::DONATION_CONFIRMATIONS_REQUIRED,
        paid: true
      }

      service = FakeMoneroService.new(
        create_subaddress_result: { subaddress: "84claimed", address_index: 11 },
        check_status_results: [ ready_status ]
      )

      with_stubbed_monero_service(service) do
        with_stubbed_signer("cafebabe") do
          post "/blind_tokens/session", as: :json
          assert_response :success
          session_id = response.parsed_body.fetch("payment_session_id")

          post "/blind_tokens/sign",
            params: {
              payment_session_id: session_id,
              blinded_message: "2a"
            },
            as: :json

          assert_response :success
          assert_equal "cafebabe", response.parsed_body.fetch("signed_message")

          post "/blind_tokens/sign",
            params: {
              payment_session_id: session_id,
              blinded_message: "2b"
            },
            as: :json

          assert_response :conflict
          assert_equal "payment_already_claimed", response.parsed_body.fetch("error")
        end
      end
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

  def with_stubbed_monero_service(service)
    singleton = MoneroPaymentService.singleton_class
    original_new = MoneroPaymentService.method(:new)
    singleton.define_method(:new) { service }
    yield
  ensure
    singleton.define_method(:new) do |*args, **kwargs, &block|
      original_new.call(*args, **kwargs, &block)
    end
  end

  def with_stubbed_signer(signature)
    original_sign_method = BlindTokensController.instance_method(:sign_blinded_message_hex)
    BlindTokensController.define_method(:sign_blinded_message_hex) { |_blinded_message_hex| signature }
    yield
  ensure
    BlindTokensController.define_method(:sign_blinded_message_hex, original_sign_method)
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

    def set(key, value, nx: false, ex: nil)
      _ = ex
      return false if nx && @store.key?(key)

      @store[key] = value
      "OK"
    end
  end

  class FakeMoneroService
    def initialize(create_subaddress_result:, check_status_results: [])
      @create_subaddress_result = create_subaddress_result
      @check_status_results = check_status_results.dup
      @last_check_status_result = @check_status_results.last || {
        total_received_piconero: 0,
        pending_amount_piconero: 0,
        max_confirmations: 0,
        paid: false
      }
    end

    def create_subaddress(account_index: 0)
      _ = account_index
      @create_subaddress_result
    end

    def check_status(address_index:, min_amount_piconero:)
      _ = address_index
      _ = min_amount_piconero
      result = @check_status_results.shift || @last_check_status_result
      @last_check_status_result = result
      result
    end
  end
end
