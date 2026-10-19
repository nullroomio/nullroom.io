module ApplicationHelper
  # Absolute canonical URL of the current page: apex host, no query string, no trailing slash.
  def canonical_url
    path = request.path.delete_suffix("/")
    "#{Nullroom::Config::CANONICAL_ORIGIN}#{path.presence || "/"}"
  end

  def file_transfer_size_limit_label
    bytes = Nullroom::Config::FILE_TRANSFER_SIZE_LIMIT_BYTES
    mebibytes = bytes / 1024.0 / 1024.0

    mebibytes.round == mebibytes ? "#{mebibytes.to_i} MB" : "#{mebibytes.round(1)} MB"
  end
end
