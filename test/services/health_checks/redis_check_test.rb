# frozen_string_literal: true

require "test_helper"

class HealthChecks::RedisCheckTest < ActiveSupport::TestCase
  test "ok with latency against a live Redis" do
    result = HealthChecks::RedisCheck.new.run

    assert_equal "ok", result.status
    assert_kind_of Integer, result.details[:latency_ms]
  end

  test "down when Redis is unreachable" do
    result = HealthChecks::RedisCheck.new(url: "redis://127.0.0.1:1/0").run

    assert_equal "down", result.status
    assert_equal "unavailable", result.reason
  end
end
