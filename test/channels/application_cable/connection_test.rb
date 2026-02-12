require "test_helper"

module ApplicationCable
  class ConnectionTest < ActionCable::Connection::TestCase
    tests ApplicationCable::Connection

    test "uses volatile token_id instead of session cookie" do
      cookies[:token_id] = "session-cookie-token"

      connect

      assert_match(/\A[0-9a-f\-]{36}\z/i, connection.token_id)
      refute_equal cookies[:token_id], connection.token_id
    end
  end
end
