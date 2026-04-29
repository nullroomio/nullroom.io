require "test_helper"

class MoneroPaymentServiceTest < ActiveSupport::TestCase
  test "create_subaddress returns mapped response keys" do
    service = MoneroPaymentService.allocate
    client = Object.new

    def client.call(method, params = {})
      raise "unexpected method" unless method == "create_address"
      raise "unexpected params" unless params == { account_index: 2 }

      { "address" => "84abc", "address_index" => 7 }
    end

    service.instance_variable_set(:@client, client)

    result = service.create_subaddress(account_index: 2)

    assert_equal({ subaddress: "84abc", address_index: 7 }, result)
  end

  test "check_status computes totals and paid status from available transfers" do
    service = MoneroPaymentService.allocate
    client = Object.new

    # wallet height 1000; block_heights 998 and 995 → confirmations 2 and 5
    def client.call(method, params = {})
      if method == "incoming_transfers" && params == { transfer_type: "all" }
        return {
          "transfers" => [
            { "subaddr_index" => { "major" => 0, "minor" => 11 }, "amount" => 200, "block_height" => 998 },
            { "subaddr_index" => { "major" => 0, "minor" => 11 }, "amount" => 300, "block_height" => 995 },
            { "subaddr_index" => { "major" => 0, "minor" => 99 }, "amount" => 999, "block_height" => 980 }
          ]
        }
      end

      if method == "incoming_transfers" && params == { transfer_type: "pending" }
        return {
          "transfers" => [
            { "subaddr_index" => { "major" => 0, "minor" => 11 }, "amount" => 120 },
            { "subaddr_index" => { "major" => 0, "minor" => 99 }, "amount" => 20 }
          ]
        }
      end

      if method == "get_height"
        return { "height" => 1000 }
      end

      raise "unexpected call: #{method} #{params.inspect}"
    end

    service.instance_variable_set(:@client, client)

    result = service.check_status(address_index: 11, min_amount_piconero: 500)

    assert_equal 500, result.fetch(:total_received_piconero)
    assert_equal 120, result.fetch(:pending_amount_piconero)
    assert_equal 6, result.fetch(:max_confirmations)
    assert_equal true, result.fetch(:paid)
  end

  test "check_status falls back to unavailable when pending transfer type is unsupported" do
    service = MoneroPaymentService.allocate
    client = Object.new

    def client.call(method, params = {})
      if method == "incoming_transfers" && params == { transfer_type: "all" }
        return { "transfers" => [] }
      end

      if method == "incoming_transfers" && params == { transfer_type: "pending" }
        raise StandardError, "Transfer type must be one of: all, available, or unavailable"
      end

      if method == "incoming_transfers" && params == { transfer_type: "unavailable" }
        return { "transfers" => [ { "subaddr_index" => { "major" => 0, "minor" => 5 }, "amount" => 700 } ] }
      end

      if method == "get_height"
        return { "height" => 500 }
      end

      raise "unexpected call: #{method} #{params.inspect}"
    end

    service.instance_variable_set(:@client, client)

    result = service.check_status(address_index: 5, min_amount_piconero: 1_000)

    assert_equal 0, result.fetch(:total_received_piconero)
    assert_equal 700, result.fetch(:pending_amount_piconero)
    assert_equal false, result.fetch(:paid)
  end
end
