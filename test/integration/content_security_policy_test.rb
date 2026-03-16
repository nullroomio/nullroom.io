require "test_helper"

class ContentSecurityPolicyTest < ActionDispatch::IntegrationTest
  test "root response includes strict csp header" do
    get root_path

    csp = response.headers["Content-Security-Policy"]
    assert_not_nil csp

    assert_includes csp, "default-src 'self'"
    assert_includes csp, "object-src 'none'"
    assert_includes csp, "script-src 'self'"
    assert_includes csp, "style-src 'self'"
    assert_includes csp, "connect-src"
    assert_includes csp, "worker-src"

    refute_includes csp, "'unsafe-inline'"
    refute_includes csp, "'unsafe-eval'"
  end
end
