module ApplicationHelper
  def file_transfer_size_limit_label
    bytes = Nullroom::Config::FILE_TRANSFER_SIZE_LIMIT_BYTES
    mebibytes = bytes / 1024.0 / 1024.0

    mebibytes.round == mebibytes ? "#{mebibytes.to_i} MB" : "#{mebibytes.round(1)} MB"
  end
end
