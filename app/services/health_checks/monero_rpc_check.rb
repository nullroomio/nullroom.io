# frozen_string_literal: true

module HealthChecks
  # The donation flow creates subaddresses and polls transfers over the
  # wallet RPC (through Tor); a wallet that answers with a height is usable.
  class MoneroRpcCheck < Check
    def timeout
      15
    end

    def call
      MoneroPaymentService.new.wallet_height.positive? ? Result.ok : Result.down("wallet_not_synced")
    rescue RuntimeError
      Result.down("rpc_error")
    end
  end
end
