# frozen_string_literal: true

require "test_helper"

class Fygaro::OrderCreatorTest < ActiveSupport::TestCase
  setup do
    @shop = shops(:regular_shop)
    @shop.update!(shopify_token: "token")
    @checkout = FygaroCheckout.create!(
      shop: @shop,
      custom_reference: "z1z2z3z4z5z6z7z8z9z0",
      cart_token: "raw-cart-token",
      status: :paid,
      fygaro_transaction_id: "txn-123",
      customer: { email: "buyer@example.com", first_name: "Ada", last_name: "Lovelace" },
      shipping_address: { address1: "1 Main St", city: "Toronto", country: "CA", province: "ON", zip: "M5V" },
      shipping_rate: { title: "Standard", price: 900 },
      line_items: [ { variant_id: "gid://shopify/ProductVariant/1", quantity: 2 } ],
      totals: { currency: "IDR", subtotal: 100000, discount: 0, total: 100000, shipping: 900 },
      total_amount: 100900,
      currency: "IDR"
    )
  end

  test "creates the order and records the order id on the checkout" do
    client = fake_client(
      "data" => {
        "orderCreate" => {
          "order" => { "id" => "gid://shopify/Order/42", "name" => "#1001" },
          "userErrors" => []
        }
      }
    )

    order_id = Fygaro::OrderCreator.call(checkout: @checkout, client: client)
    assert_equal "gid://shopify/Order/42", order_id

    @checkout.reload
    assert_equal "gid://shopify/Order/42", @checkout.fygaro_order_id
    assert_not_nil @checkout.admin_order_created_at
  end

  test "sends an orderCreate mutation with the checkout snapshot" do
    captured = nil
    client = fake_client(
      "data" => { "orderCreate" => { "order" => { "id" => "gid://shopify/Order/7" }, "userErrors" => [] } }
    ) { |query, variables| captured = [ query, variables ] }

    Fygaro::OrderCreator.call(checkout: @checkout, client: client)

    query, variables = captured
    assert_includes query, "orderCreate"
    input = variables.fetch(:input)
    assert_equal [ { variantId: "gid://shopify/ProductVariant/1", quantity: 2 } ], input[:lineItems]
    assert_equal "Standard", input.dig(:shippingLine, :title)
    assert_equal({ amount: "9.00" }, input.dig(:shippingLine, :price))
    assert_equal "CA", input.dig(:shippingAddress, :countryCode)
    assert_equal "buyer@example.com", input.dig(:customer, :email)
    assert_equal [ "fygaro", "z1z2z3z4z5z6z7z8z9z0" ], input[:tags]
    assert_equal "CUSTOM", input.dig(:payment, :type)
    assert_equal "txn-123", input.dig(:payment, :paymentIdentifier)
    assert_equal "1009.00", input.dig(:payment, :paymentAmount)
  end

  test "raises AlreadyCreated when the checkout already has an order id" do
    @checkout.update!(fygaro_order_id: "gid://shopify/Order/99")

    assert_raises(Fygaro::OrderCreator::AlreadyCreated) do
      Fygaro::OrderCreator.call(checkout: @checkout, client: fake_client({}))
    end
  end

  test "raises AdminAccessError on userErrors" do
    client = fake_client(
      "data" => { "orderCreate" => { "order" => nil, "userErrors" => [ { "field" => "payment", "message" => "nope" } ] } }
    )

    assert_raises(Fygaro::OrderCreator::AdminAccessError) do
      Fygaro::OrderCreator.call(checkout: @checkout, client: client)
    end
  end

  test "raises AdminAccessError when no Shopify session exists" do
    ShopifyApp::SessionRepository.stub(:retrieve_shop_session_by_shopify_domain, ->(*) { nil }) do
      assert_raises(Fygaro::OrderCreator::AdminAccessError) do
        Fygaro::OrderCreator.call(checkout: @checkout)
      end
    end
  end

  private

  def fake_client(body, &block)
    Struct.new(:body, :capture) do
      def query(query:, variables: nil, response_as_struct: false)
        capture&.call(query, variables)
        Struct.new(:body).new(body)
      end

      def respond_to_missing?(*)
        true
      end
    end.new(body, block)
  end
end
