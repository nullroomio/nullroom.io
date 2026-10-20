# frozen_string_literal: true

require "test_helper"

class StatusControllerTest < ActionDispatch::IntegrationTest
  test "page renders instantly without running checks" do
    with_report(-> { flunk "the page shell must not run checks" }) do
      get status_page_path

      assert_response :success
      assert_select "meta[name=robots][content=?]", "noindex, nofollow"
      assert_select "h1", "System Status"
      assert_select "turbo-frame#status-checks[src=?]", status_checks_path
      assert_match "Running checks", response.body
      assert_equal "no-store", response.headers["Cache-Control"]
    end
  end

  test "checks frame renders component states without detail text" do
    with_report(report("degraded", "cert_turn", "degraded", "cert_expiring", "days_left" => 15, "expires_on" => "2026-11-04")) do
      get status_checks_path

      assert_response :success
      assert_select "turbo-frame#status-checks"
      assert_select "dt", "cert_turn"
      assert_select "[data-controller=status-refresh]:not([data-status-refresh-interval-value])"
      assert_match "Some systems degraded", response.body
      assert_match "Degraded", response.body
      assert_no_match "2026-11-04", response.body
      assert_no_match "<html", response.body
    end
  end

  test "json answers 200 with release info when critical components are ok" do
    with_report(report("ok", "redis", "ok", nil, "latency_ms" => 1)) do
      get "/status.json"

      assert_response :success
      body = response.parsed_body
      assert_equal "ok", body["status"]
      assert_equal "redis", body["components"].first["id"]
      assert_equal({ "commit" => "dev" }, body["release"])
      assert_not body["components"].first.key?("details")
    end
  end

  test "json answers 503 when a critical component is not ok" do
    with_report(report("down", "turn", "down", "auth_failed")) do
      get "/status.json"

      assert_response :service_unavailable
      assert_equal "down", response.parsed_body["components"].first["status"]
      assert_not response.parsed_body["components"].first.key?("reason")
    end
  end

  test "json answers 503 pending before the first run completes" do
    with_report(nil) do
      get "/status.json"

      assert_response :service_unavailable
      assert_equal "pending", response.parsed_body["status"]
      assert_equal "5", response.headers["Retry-After"]
    end
  end

  test "checks frame polls quickly before the first run completes" do
    with_report(nil) do
      get status_checks_path

      assert_response :success
      assert_select "turbo-frame#status-checks [data-controller=status-refresh][data-status-refresh-interval-value=?]", "3000"
      assert_match "Running checks", response.body
    end
  end

  private

  def report(overall, id, status, reason, details = {})
    {
      "status" => overall,
      "checked_at" => Time.now.utc.iso8601,
      "components" => [
        { "id" => id, "name" => id, "group" => "core", "critical" => true, "status" => status, "reason" => reason, "details" => details }
      ]
    }
  end

  # Accepts a report hash, or a proc to run in place of Report.current.
  def with_report(report)
    HealthChecks::Report.singleton_class.alias_method(:original_current, :current)
    HealthChecks::Report.define_singleton_method(:current) { report.respond_to?(:call) ? report.call : report }
    yield
  ensure
    HealthChecks::Report.singleton_class.alias_method(:current, :original_current)
    HealthChecks::Report.singleton_class.remove_method(:original_current)
  end
end
