require "test_helper"

class IntegrityIndicatorTest < ActionDispatch::IntegrationTest
  test "root page includes integrity manifest script tag" do
    get root_path
    assert_response :success
    assert_select 'script[type="application/json"]#integrity-manifest'
  end

  test "root page includes commit SHA data attribute" do
    get root_path
    assert_response :success
    assert_select "html[data-commit-sha]"
  end

  test "root page renders integrity indicator partial" do
    get root_path
    assert_response :success
    assert_select '[data-controller="integrity"]'
  end

  test "commit SHA defaults to dev when env is unset" do
    get root_path
    assert_select 'html[data-commit-sha="dev"]'
  end

  test "privacy page includes integrity indicator" do
    get privacy_page_path
    assert_response :success
    assert_select '[data-controller="integrity"]'
    assert_select 'script[type="application/json"]#integrity-manifest'
  end
end
