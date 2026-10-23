require "test_helper"

class ArticlesControllerTest < ActionDispatch::IntegrationTest
  test "index links to every article" do
    get articles_path
    assert_response :success
    assert_select 'link[rel="canonical"][href="https://nullroom.io/learn"]'

    Article.all.each do |article|
      assert_select "a[href=?]", article_path(article)
    end
  end

  test "each article renders with its canonical URL and Article markup" do
    Article.all.each do |article|
      get article_path(article)
      assert_response :success
      assert_select "h1", article.headline
      assert_select 'link[rel="canonical"][href=?]', article.url
      assert_select 'meta[property="og:type"][content="article"]'

      json_ld = css_select('script[type="application/ld+json"]').map { |node| JSON.parse(node.text) }
      markup = json_ld.find { |data| data["@type"] == "Article" }
      assert_equal article.headline, markup["headline"]
      assert_equal article.url, markup["mainEntityOfPage"]
    end
  end

  test "unknown article is not found" do
    get "/learn/does-not-exist"
    assert_response :not_found
  end

  test "sitemap lists the index and every article" do
    locs = Rails.public_path.join("sitemap.xml").read.scan(%r{<loc>(.*?)</loc>}).flatten

    assert_includes locs, "https://nullroom.io/learn"
    Article.all.each { |article| assert_includes locs, article.url }
  end
end
