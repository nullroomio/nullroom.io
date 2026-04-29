require "json"
require "digest/md5"
require "net/http"
require "open3"
require "securerandom"
require "socksify/http"

# Handles all transport concerns for the Monero JSON-RPC API:
# SOCKS5/Tor proxy routing, HTTP Digest authentication, curl fallback,
# and JSON-RPC envelope encoding/decoding.
#
# Usage:
#   client = MoneroRpcClient.new(url:, username:, password:, tor_socks_host:, tor_socks_port:)
#   result = client.call("create_address", account_index: 0)
class MoneroRpcClient
  def initialize(url:, username:, password:, tor_socks_host:, tor_socks_port:)
    @url = url
    @username = username
    @password = password
    @tor_socks_host = tor_socks_host
    @tor_socks_port = tor_socks_port
  end

  # Executes a JSON-RPC method call and returns the parsed `result` hash.
  # Raises on HTTP errors or RPC-level errors.
  def call(method, params = {})
    uri = URI.parse(@url)
    payload = JSON.generate({
      jsonrpc: "2.0",
      id: "nullroom-pro",
      method: method,
      params: params
    })

    response = digest_authenticated_post(uri: uri, body: payload)
    response = curl_digest_fallback(uri: uri, body: payload) if response.code.to_i == 401

    unless response.is_a?(Net::HTTPSuccess)
      raise "Monero RPC HTTP error #{response.code}: #{response.body}"
    end

    parsed = JSON.parse(response.body)
    if parsed["error"].present?
      raise "Monero RPC error: #{parsed['error'].inspect}"
    end

    parsed.fetch("result")
  end

  private

  def digest_authenticated_post(uri:, body:)
    http = build_http_client(uri)
    request_path = uri.request_uri.presence || "/json_rpc"

    first_request = Net::HTTP::Post.new(request_path)
    first_request["Content-Type"] = "application/json"
    first_request.body = body

    first_response = http.request(first_request)
    return first_response if first_response.is_a?(Net::HTTPSuccess)
    return first_response unless first_response.code.to_i == 401

    challenge_header = first_response["www-authenticate"].to_s
    auth_header = build_digest_authorization(
      challenge_header: challenge_header,
      http_method: "POST",
      request_path: request_path,
      body: body
    )

    second_request = Net::HTTP::Post.new(request_path)
    second_request["Content-Type"] = "application/json"
    second_request["Authorization"] = auth_header
    second_request.body = body

    http.request(second_request)
  end

  def curl_digest_fallback(uri:, body:)
    cmd = [
      "curl",
      "--silent",
      "--show-error",
      "--digest",
      "-u",
      "#{@username}:#{@password}",
      "-H",
      "Content-Type: application/json",
      "-d",
      body,
      uri.to_s
    ]

    if onion_host?(uri.host)
      cmd.insert(3, "--socks5-hostname")
      cmd.insert(4, "#{@tor_socks_host}:#{@tor_socks_port}")
    end

    stdout, stderr, status = Open3.capture3(*cmd)
    unless status.success?
      raise "Monero RPC curl fallback failed: #{stderr.presence || stdout.presence || 'unknown error'}"
    end

    response = Net::HTTPOK.new("1.1", "200", "OK")
    response.instance_variable_set(:@read, true)
    response.body = stdout
    response
  end

  def build_http_client(uri)
    http = if onion_host?(uri.host)
      raise "Tor SOCKS host not configured for onion Monero RPC" if @tor_socks_host.blank?
      raise "Invalid Tor SOCKS port for onion Monero RPC" if @tor_socks_port <= 0

      Net::HTTP.SOCKSProxy(@tor_socks_host, @tor_socks_port).new(uri.host, uri.port)
    else
      Net::HTTP.new(uri.host, uri.port)
    end

    http.use_ssl = (uri.scheme == "https")
    http.open_timeout = 20
    http.read_timeout = 30
    http
  end

  def onion_host?(host)
    host.to_s.downcase.end_with?(".onion")
  end

  def build_digest_authorization(challenge_header:, http_method:, request_path:, body:)
    challenge = parse_digest_challenge(challenge_header)
    raise "Monero RPC digest challenge missing" if challenge.empty?

    realm = challenge.fetch("realm")
    nonce = challenge.fetch("nonce")
    qop = choose_qop(challenge["qop"])
    opaque = challenge["opaque"]
    algorithm = (challenge["algorithm"] || "MD5").upcase

    nc = "00000001"
    cnonce = SecureRandom.hex(16)

    ha1 = Digest::MD5.hexdigest("#{@username}:#{realm}:#{@password}")
    if algorithm == "MD5-SESS"
      ha1 = Digest::MD5.hexdigest("#{ha1}:#{nonce}:#{cnonce}")
    elsif algorithm != "MD5"
      raise "Unsupported digest algorithm: #{algorithm}"
    end

    ha2 = if qop == "auth-int"
      body_hash = Digest::MD5.hexdigest(body)
      Digest::MD5.hexdigest("#{http_method}:#{request_path}:#{body_hash}")
    else
      Digest::MD5.hexdigest("#{http_method}:#{request_path}")
    end

    response_digest = if qop
      Digest::MD5.hexdigest("#{ha1}:#{nonce}:#{nc}:#{cnonce}:#{qop}:#{ha2}")
    else
      Digest::MD5.hexdigest("#{ha1}:#{nonce}:#{ha2}")
    end

    parts = [
      %(Digest username="#{@username}"),
      %(realm="#{realm}"),
      %(nonce="#{nonce}"),
      %(uri="#{request_path}"),
      %(response="#{response_digest}")
    ]
    parts << %(algorithm=#{algorithm})
    parts << %(opaque="#{opaque}") if opaque.present?

    if qop
      parts << %(qop=#{qop})
      parts << %(nc=#{nc})
      parts << %(cnonce="#{cnonce}")
    end

    parts.join(", ")
  end

  def parse_digest_challenge(header)
    return {} if header.blank?

    # Some servers return multiple Digest challenges in a single header
    # (for example MD5 and MD5-sess). Parse only the first challenge.
    first_challenge = header.split(/\s*,\s*Digest\s+/i).first.to_s
    digest_part = first_challenge.sub(/\ADigest\s+/i, "")
    values = {}
    digest_part.scan(/(\w+)=(?:"([^"]*)"|([^,]+))/).each do |key, quoted, plain|
      values[key.downcase] = (quoted.presence || plain.to_s.strip)
    end
    values
  end

  def choose_qop(qop_header)
    return nil if qop_header.blank?

    options = qop_header.split(",").map { |item| item.strip.downcase }
    return "auth" if options.include?("auth")
    return "auth-int" if options.include?("auth-int")

    nil
  end
end
