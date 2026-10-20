# frozen_string_literal: true

require "test_helper"

class HealthChecks::ReportTest < ActiveSupport::TestCase
  Result = HealthChecks::Result
  Component = HealthChecks::Report::Component

  class FakeCheck
    attr_reader :calls

    def initialize(result)
      @result = result
      @calls = 0
    end

    def run
      @calls += 1
      @result
    end
  end

  # Blocks inside the check until released, to observe a refresh in flight.
  class BlockingCheck < FakeCheck
    def initialize(gate)
      super(Result.ok)
      @gate = gate
    end

    def run
      @gate.pop
      super
    end
  end

  class UnavailableRedis
    def method_missing(*) = raise(Redis::CannotConnectError, "down")
    def respond_to_missing?(*) = true
  end

  setup do
    @cache_key = "test:status:#{SecureRandom.hex(8)}"
  end

  teardown do
    REDIS.del(@cache_key, "#{@cache_key}:lock")
    HealthChecks::Report::LOCAL_CACHE.delete(@cache_key)
  end

  test "ok when every component is ok" do
    report = report_for(critical: Result.ok, optional: Result.ok).build

    assert_equal "ok", report["status"]
    assert HealthChecks::Report.healthy?(report)
  end

  test "degraded when only a non-critical component is down" do
    report = report_for(critical: Result.ok, optional: Result.down("timeout")).build

    assert_equal "degraded", report["status"]
    assert HealthChecks::Report.healthy?(report)
  end

  test "degraded but unhealthy when a critical component is degraded" do
    report = report_for(critical: Result.degraded("cert_expiring", days_left: 15), optional: Result.ok).build

    assert_equal "degraded", report["status"]
    assert_not HealthChecks::Report.healthy?(report)
    assert_equal({ "days_left" => 15 }, report["components"].first["details"])
  end

  test "down when a critical component is down" do
    report = report_for(critical: Result.down("cert_expired"), optional: Result.ok).build

    assert_equal "down", report["status"]
    assert_equal "cert_expired", report["components"].first["reason"]
  end

  test "serves the cached report while fresh" do
    check = FakeCheck.new(Result.ok)
    report = HealthChecks::Report.new(components: [ Component.new("a", "A", "core", true, check) ], cache_key: @cache_key, async: false)

    first = report.current
    second = report.current

    assert_equal 1, check.calls
    assert_equal first, second
  end

  test "refreshes once the cached report is stale" do
    check = FakeCheck.new(Result.ok)
    report = HealthChecks::Report.new(components: [ Component.new("a", "A", "core", true, check) ], cache_key: @cache_key, async: false)

    report.current
    travel HealthChecks::Report::MAX_AGE + 1 do
      report.current
    end

    assert_equal 2, check.calls
  end

  test "requests never wait on checks and only one refresh runs at a time" do
    gate = Queue.new
    check = BlockingCheck.new(gate)
    report = HealthChecks::Report.new(components: [ Component.new("a", "A", "core", true, check) ], cache_key: @cache_key)

    assert_nil report.current
    assert_nil report.current

    gate << :release
    assert wait_for { REDIS.get(@cache_key) }, "background refresh never wrote the report"
    assert_equal "ok", report.current["status"]
    assert_equal 1, check.calls
  ensure
    gate << :release
  end

  test "keeps working from the in-process copy while Redis is down" do
    check = FakeCheck.new(Result.ok)

    with_redis(UnavailableRedis.new) do
      report = HealthChecks::Report.new(components: [ Component.new("a", "A", "core", true, check) ], cache_key: @cache_key, async: false)

      assert_equal "ok", report.current["status"]
      report.current
    end

    assert_equal 1, check.calls
  end

  test "public view drops reason codes and details" do
    report = report_for(critical: Result.down("auth_failed", latency_ms: 3), optional: Result.ok).build
    component = HealthChecks::Report.public_view(report)["components"].first

    assert_equal({ "id" => "critical", "name" => "Critical", "group" => "core", "critical" => true, "status" => "down" }, component)
  end

  private

  def wait_for(seconds: 2)
    deadline = Time.now + seconds
    sleep 0.01 until (result = yield) || Time.now > deadline
    result
  end

  def with_redis(redis)
    original = REDIS
    Object.send(:remove_const, :REDIS)
    Object.const_set(:REDIS, redis)
    yield
  ensure
    Object.send(:remove_const, :REDIS)
    Object.const_set(:REDIS, original)
  end

  def report_for(critical:, optional:)
    HealthChecks::Report.new(
      components: [
        Component.new("critical", "Critical", "core", true, FakeCheck.new(critical)),
        Component.new("optional", "Optional", "donations", false, FakeCheck.new(optional))
      ],
      cache_key: @cache_key
    )
  end
end
