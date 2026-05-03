require "test_helper"

class BlindTokenGateTestController < ApplicationController
  before_action :require_blind_token!

  def show
    render json: { ok: true }
  end
end

class ApplicationControllerTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::TimeHelpers

  parallelize(workers: 1)

  setup do
    Rails.application.routes.disable_clear_and_finalize = true
    Rails.application.routes.draw do
      get "/test_blind_token_gate" => "blind_token_gate_test#show"
    end
  end

  teardown do
    travel_back
    Rails.application.reload_routes!
  end

  test "require_blind_token consumes the token and rejects replay after unlock expiry" do
    verifier = FakeVerifier.new
    headers = {
      "X-Blind-Token-Message" => "aa",
      "X-Blind-Token-Signature" => "bb"
    }

    with_stubbed_verifier(verifier) do
      get "/test_blind_token_gate", headers: headers
      assert_response :success
      assert_equal 1, verifier.consume_calls

      get "/test_blind_token_gate", headers: headers
      assert_response :success
      assert_equal 1, verifier.consume_calls

      travel Nullroom::Config::DONATION_SESSION_UNLOCK_TTL_SECONDS + 1

      get "/test_blind_token_gate", headers: headers
      assert_response :unauthorized
      assert_equal "invalid_blind_token", response.parsed_body.fetch("error")
      assert_equal 2, verifier.consume_calls
    end
  end

  private

  def with_stubbed_verifier(verifier)
    original_new = BlindTokenVerifier.method(:new)
    BlindTokenVerifier.singleton_class.define_method(:new) { verifier }
    yield
  ensure
    BlindTokenVerifier.singleton_class.define_method(:new) do |*args, **kwargs, &block|
      original_new.call(*args, **kwargs, &block)
    end
  end

  class FakeVerifier
    attr_reader :consume_calls

    def initialize
      @consume_calls = 0
      @spent = false
    end

    def consume!(message_hex:, signature_hex:)
      _ = message_hex
      _ = signature_hex
      @consume_calls += 1
      return false if @spent

      @spent = true
      true
    end
  end
end
