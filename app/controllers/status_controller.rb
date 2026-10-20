# StatusController serves the public status page at /status (and /status.json).
#
# Unlike /up (a cheap liveness probe for kamal-proxy), this reports deep checks
# of every critical path — TLS certificates as actually served, a real TURN
# allocation, signaling pub/sub — from HealthChecks::Report, which refreshes
# them in the background at most once a minute. Requests never wait on checks.
#
# The HTML page renders instantly as a shell; the checks load into a Turbo
# Frame from #checks. The JSON form answers 503 when any critical component is
# not ok, so a plain uptime monitor can alert on it without parsing the body.
# Only component states are published — reason codes and details stay in the
# cached report for operators.
class StatusController < ApplicationController
  before_action { response.headers["Cache-Control"] = "no-store" }

  def show
    respond_to do |format|
      format.html
      format.json { render_json(HealthChecks::Report.current) }
    end
  end

  # GET /status/checks — the Turbo Frame with component states.
  # Renders a pending state (and polls again shortly) before the first run completes.
  def checks
    report = HealthChecks::Report.current
    @report = report && HealthChecks::Report.public_view(report)
    render layout: false
  end

  private

  def render_json(report)
    if report.nil?
      response.headers["Retry-After"] = "5"
      render json: { status: "pending" }, status: :service_unavailable
      return
    end

    render json: HealthChecks::Report.public_view(report).merge("release" => { "commit" => helpers.commit_sha }),
      status: HealthChecks::Report.healthy?(report) ? :ok : :service_unavailable
  end
end
