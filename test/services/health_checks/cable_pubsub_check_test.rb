# frozen_string_literal: true

require "test_helper"

class HealthChecks::CablePubsubCheckTest < ActiveSupport::TestCase
  test "ok when a broadcast reaches the subscriber" do
    assert_equal "ok", HealthChecks::CablePubsubCheck.new.run.status
  end
end
