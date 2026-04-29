class MoneroPaymentService
  def initialize
    rpc_url      = Rails.application.credentials.dig(:monero, :rpc_url)
    rpc_username = Rails.application.credentials.dig(:monero, :rpc_username)
    rpc_password = Rails.application.credentials.dig(:monero, :rpc_password)

    raise "Monero RPC credentials not configured" if rpc_url.blank? || rpc_username.blank? || rpc_password.blank?

    @client = MoneroRpcClient.new(
      url:            rpc_url,
      username:       rpc_username,
      password:       rpc_password,
      tor_socks_host: tor_socks_host,
      tor_socks_port: tor_socks_port
    )
  end

  # Creates a unique payment address in account 0.
  # Returns a hash with keys: :subaddress, :address_index
  def create_subaddress(account_index: 0)
    result = @client.call("create_address", account_index: account_index)

    {
      subaddress:    result.fetch("address"),
      address_index: result.fetch("address_index")
    }
  end

  # Checks payment status for a specific subaddress by scanning incoming transfers.
  # Returns a hash with total_received_piconero, max_confirmations, and paid flag.
  # Matches transfers by subaddr_index minor (incoming_transfers does not return an address field).
  def check_status(address_index:, min_amount_piconero:)
    minimum_amount = Integer(min_amount_piconero)
    idx = Integer(address_index)
    available = @client.call("incoming_transfers", transfer_type: "all").fetch("transfers", [])
    pending   = incoming_pending_transfers
    wallet_height = current_wallet_height

    matching_available = available.select { |tx| tx.dig("subaddr_index", "minor") == idx }
    matching_pending   = pending.select   { |tx| tx.dig("subaddr_index", "minor") == idx }

    total_received    = matching_available.sum { |tx| tx["amount"].to_i }
    max_confirmations = matching_available.map { |tx| confirmations_for(tx, wallet_height) }.max || 0

    {
      total_received_piconero:  total_received,
      pending_amount_piconero:  matching_pending.sum { |tx| tx["amount"].to_i },
      max_confirmations:        max_confirmations,
      paid:                     total_received >= minimum_amount
    }
  rescue StandardError => e
    Rails.logger.error("MoneroPaymentService check_status error: #{e.class}: #{e.message}")
    raise
  end

  private

  def incoming_pending_transfers
    @client.call("incoming_transfers", transfer_type: "pending").fetch("transfers", [])
  rescue StandardError => e
    raise unless e.message.to_s.downcase.include?("transfer type must be one of")

    @client.call("incoming_transfers", transfer_type: "unavailable").fetch("transfers", [])
  end

  def current_wallet_height
    @client.call("get_height").fetch("height", 0)
  end

  # Computes confirmations from wallet height and tx block_height.
  # incoming_transfers does not return a confirmations field directly.
  # A tx in block N with wallet height N has 1 confirmation.
  def confirmations_for(tx, wallet_height)
    block_height = tx["block_height"].to_i
    return 0 if block_height <= 0 || wallet_height <= 0

    [ wallet_height - block_height + 1, 0 ].max
  end

  def tor_socks_host
    Rails.application.credentials.dig(:monero, :tor_socks_host).presence ||
      ENV["NULLROOM_MONERO_TOR_SOCKS_HOST"].presence ||
      "nullroom-tor"
  end

  def tor_socks_port
    raw = Rails.application.credentials.dig(:monero, :tor_socks_port).presence ||
      ENV["NULLROOM_MONERO_TOR_SOCKS_PORT"].presence ||
      "9150"
    Integer(raw)
  rescue ArgumentError
    0
  end
end
