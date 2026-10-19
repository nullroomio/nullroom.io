require "test_helper"

class SeoMetaTest < ActionDispatch::IntegrationTest
  test "root declares the apex canonical URL" do
    get root_path
    assert_response :success
    assert_select 'html[lang="en"]'
    assert_select 'link[rel="canonical"][href="https://nullroom.io/"]'
    assert_select 'meta[property="og:url"][content="https://nullroom.io/"]'
  end

  test "canonical URL drops the query string and trailing slash" do
    get "/faq/?utm_source=test"
    assert_response :success
    assert_select 'link[rel="canonical"][href="https://nullroom.io/faq"]'
  end

  test "GET /rooms no longer duplicates the landing page" do
    get "/rooms"
    assert_response :not_found
  end

  test "sitemap lists only the apex host and no health check" do
    sitemap = Rails.public_path.join("sitemap.xml").read
    locs = sitemap.scan(%r{<loc>(.*?)</loc>}).flatten

    assert locs.all? { |loc| loc.start_with?("https://nullroom.io/") }
    assert_not_includes locs, "https://nullroom.io/up"
  end
end
