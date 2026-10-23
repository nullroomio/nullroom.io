# Long-form articles served under /learn.
#
# Each body is a static partial at app/views/articles/_<slug with underscores>.html.erb.
# Articles also syndicated elsewhere (e.g. Medium) must point their canonical
# link back to #url so search engines treat nullroom.io as the original.
Article = Data.define(:slug, :headline, :title, :description, :dek, :published_on, :reading_minutes) do
  # self:: because constants in a Data.define block resolve lexically, not on Article.
  def self.all
    self::ALL.sort_by(&:published_on).reverse
  end

  def self.find(slug)
    all.find { |article| article.slug == slug }
  end

  def to_param
    slug
  end

  def partial
    "articles/#{slug.tr("-", "_")}"
  end

  def url
    "#{Nullroom::Config::CANONICAL_ORIGIN}/learn/#{slug}"
  end
end

Article::AUTHOR = "Dimitris K."

Article::ALL = [
  Article.new(
    slug: "how-nullroom-encryption-works",
    headline: "How nullroom's Encryption Works (for non-crypto developers)",
    title: "How Nullroom's Encryption Works, Explained for Developers",
    description: "A plain-English walkthrough of nullroom's end-to-end encryption: AES-GCM 256, URL-fragment keys, PBKDF2, ML-KEM-768 post-quantum key exchange and HKDF hybrid keys.",
    dek: "From room creation to encrypted messages and files: every key, where it is born, and why the server never sees it.",
    published_on: Date.new(2026, 5, 8),
    reading_minutes: 15
  ),
  Article.new(
    slug: "harvest-now-decrypt-later",
    headline: "The 2026 Reality: Why \"Harvest Now, Decrypt Later\" Just Made Every Server a Liability",
    title: "Harvest Now, Decrypt Later: Why Every Server Is a Liability",
    description: "Post-quantum algorithms protect content, not architecture. Why HNDL makes centralized servers the attack surface, and how stateless P2P removes the harvest phase.",
    dek: "Post-quantum math is only half the battle. To survive the quantum era, we must move toward a stateless, serverless architecture.",
    published_on: Date.new(2026, 5, 10),
    reading_minutes: 10
  ),
  Article.new(
    slug: "anonymous-sources-without-a-server-trail",
    headline: "How to Communicate with Anonymous Sources in 2026 Without a Server Trail",
    title: "How to Talk to Anonymous Sources Without a Server Trail",
    description: "A zero-footprint protocol for journalists: why disappearing messages still leave metadata, and how stateless, post-quantum P2P rooms protect sources.",
    dek: "Why traditional \"disappearing messages\" aren't enough, and how stateless P2P tech is closing the metadata gap.",
    published_on: Date.new(2026, 5, 9),
    reading_minutes: 7
  )
].freeze
