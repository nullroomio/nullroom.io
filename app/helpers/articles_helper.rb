module ArticlesHelper
  # schema.org Article markup; publisher refers to the Organization node in the layout.
  def article_json_ld(article)
    {
      "@context": "https://schema.org",
      "@type": "Article",
      headline: article.headline,
      description: article.description,
      datePublished: article.published_on.iso8601,
      dateModified: article.published_on.iso8601,
      mainEntityOfPage: article.url,
      image: "#{Nullroom::Config::CANONICAL_ORIGIN}/icon.png",
      author: { "@type": "Person", name: Article::AUTHOR },
      publisher: { "@id": "#{Nullroom::Config::CANONICAL_ORIGIN}/#organization" }
    }
  end
end
