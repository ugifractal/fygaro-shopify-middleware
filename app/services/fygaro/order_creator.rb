# frozen_string_literal: true

module Fygaro
  # Creates the Shopify Order for a paid FygaroCheckout directly via the Admin
  # GraphQL API (orderCreate). Runs after the Fygaro payment hook verifies and
  # marks the checkout paid.
  #
  # The order is created in the shop's native currency from the snapshot taken
  # at checkout time — the line-item variants, shipping line, and customer.
  # Because the buyer already paid Fygaro off-platform, we record a custom
  # payment (type CUSTOM, gateway "fygaro") referencing the Fygaro transaction
  # id so the resulting order is marked paid with a clear audit trail.
  #
  # Idempotent: if the checkout already has an order id on file we do not create
  # a second order.
  class OrderCreator
    class AdminAccessError < StandardError; end
    class AlreadyCreated < StandardError; end

    CREATE_ORDER = <<~GRAPHQL
      mutation FygaroCreateOrder($input: OrderCreateOrderInput!) {
        orderCreate(input: $input) {
          order {
            id
            name
          }
          userErrors {
            field
            message
          }
        }
      }
    GRAPHQL

    def self.call(checkout:, client: nil)
      new(checkout, client: client).call
    end

    def initialize(checkout, client: nil)
      @checkout = checkout
      @client = client
    end

    def call
      raise AlreadyCreated, "Order already created for #{@checkout.custom_reference}" if @checkout.fygaro_order_id.present?

      body = admin_client.query(query: CREATE_ORDER, variables: { input: order_input }, response_as_struct: false).body
      data = body.dig("data", "orderCreate")
      raise AdminAccessError, user_error_message(data) if data.nil? || Array(data["userErrors"]).any?

      order_id = data.dig("order", "id")
      raise AdminAccessError, "orderCreate returned no order for #{@checkout.custom_reference}" if order_id.blank?

      @checkout.update!(fygaro_order_id: order_id, admin_order_created_at: Time.current)
      order_id
    end

    private

    # Injected for tests; production builds a live Admin GraphQL client scoped
    # to the store's session.
    def admin_client
      @client || build_admin_client
    end

    def build_admin_client
      session = ShopifyApp::SessionRepository.retrieve_shop_session_by_shopify_domain(@checkout.shop.shopify_domain)
      raise AdminAccessError, "No Shopify session for #{@checkout.shop.shopify_domain}" if session.nil?

      ShopifyAPI::Clients::Graphql::Admin.new(session: session, api_version: @checkout.shop.api_version)
    end

    def order_input
      {
        email: customer["email"],
        customer: customer_input,
        shippingAddress: shipping_address,
        shippingLine: shipping_line,
        lineItems: line_items,
        tags: tags,
        customAttributes: custom_attributes,
        payment: payment
      }.compact
    end

    def customer
      @checkout.customer || {}
    end

    # Pass the buyer inline so an order can be created without needing a
    # pre-existing customer id in Shopify.
    def customer_input
      {
        email: customer["email"],
        firstName: customer["first_name"],
        lastName: customer["last_name"],
        phone: customer["phone"]
      }.compact
    end

    def tags
      [ "fygaro", @checkout.custom_reference.to_s ]
    end

    # Embed the Fygaro transaction id so it survives the round-trip into the
    # created order's custom attributes (readable in the Shopify admin).
    def custom_attributes
      [
        { key: "fygaro_transaction_id", value: @checkout.fygaro_transaction_id.to_s },
        { key: "fygaro_reference", value: @checkout.custom_reference.to_s }
      ]
    end

    def shipping_address
      address = @checkout.shipping_address || {}
      {
        address1: value(address, :address1),
        address2: value(address, :address2),
        city: value(address, :city),
        countryCode: value(address, :country).to_s.upcase.presence,
        provinceCode: value(address, :province),
        zip: value(address, :zip)
      }.compact
    end

    def shipping_line
      rate = @checkout.shipping_rate || {}
      {
        title: value(rate, :title) || "Shipping",
        price: { amount: minor_to_decimal(value(rate, :price)) }
      }.compact
    end

    def line_items
      (@checkout.line_items || []).map do |item|
        {
          variantId: value(item, :variant_id),
          quantity: value(item, :quantity)
        }.compact
      end
    end

    # Record the off-platform Fygaro tender as a custom payment so the order is
    # created as paid, referencing the Fygaro transaction for reconciliation.
    def payment
      {
        type: "CUSTOM",
        gateway: "fygaro",
        paymentIdentifier: @checkout.fygaro_transaction_id.to_s,
        paymentAmount: minor_to_decimal(@checkout.total_amount)
      }
    end

    def minor_to_decimal(minor_units)
      format("%.2f", minor_units.to_f / 100) if minor_units
    end

    def value(hash, key)
      hash[key.to_s] || hash[key]
    end

    def user_error_message(data)
      errors = Array(data["userErrors"]).map { |e| [ e["field"], e["message"] ].compact.join(": ") }
      errors.empty? ? "Unknown Shopify GraphQL error" : errors.join("; ")
    end
  end
end
