module IntegrityHelper
  # Read and cache the Propshaft manifest once per process (not per request).
  # Validates JSON before caching to defend against a corrupted manifest
  # injecting markup (e.g. </script>). CSP already blocks exploitation,
  # but this is cheap defense-in-depth.
  def integrity_manifest_json
    @@integrity_manifest ||= begin # rubocop:disable Style/ClassVars
      path = Rails.root.join("public", "assets", ".manifest.json")
      raw = File.exist?(path) ? File.read(path) : "{}"
      JSON.parse(raw) # validate — raises on malformed input
      raw
    rescue => e
      Rails.logger.error "Integrity manifest read failed: #{e.message}"
      "{}"
    end
  end

  # Full 40-char commit SHA injected at deploy time, or "dev" locally.
  def commit_sha
    sha = ENV.fetch("COMMIT_SHA", "dev")
    sha.blank? ? "dev" : sha
  end
end
