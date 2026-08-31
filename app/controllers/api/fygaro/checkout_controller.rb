# frozen_string_literal: true

class Api::Fygaro::CheckoutController < ApplicationController
  include ShopifyApp::AppProxyVerification

  before_action :set_shop
  before_action :ensure_storefront_token

  def shipping_rates
    quote = Fygaro::Quote.call(
      shop: @shop,
      cart_token: payload.fetch(:cart_token),
      shipping_address: payload.fetch(:shipping_address)
    )

    render json: { rates: quote.rates, totals: quote.totals }
  rescue KeyError => e
    render json: { error: "Missing field: #{e.key}" }, status: :bad_request
  rescue Fygaro::Quote::CartNotFoundError, Fygaro::Quote::StorefrontAccessDenied,
         Fygaro::Quote::InvalidCountryError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def sessions
    quote = Fygaro::Quote.call(
      shop: @shop,
      cart_token: payload.fetch(:cart_token),
      shipping_address: payload.fetch(:shipping_address)
    )
    rate = payload.dig(:shipping_rate)

    raise ArgumentError, "Missing shipping_rate" if rate.blank?

    matching = quote.rates.find { |option| option[:handle] == rate[:handle] }
    raise Fygaro::Quote::CartNotFoundError, "Shipping rate no longer available" if matching.nil?
    if matching[:price] != rate[:price].to_i
      raise Fygaro::Quote::CartNotFoundError, "Shipping rate price changed"
    end

    totals = quote.totals.merge(shipping: matching[:price])
    total_amount = quote.totals[:total] + matching[:price]
    custom_reference = SecureRandom.hex(16)

    # Snapshot the checkout so the Fygaro webhook (which only echoes back
    # custom_reference + amount/currency) can reconstruct the full order details
    # — line items, shipping, totals — without them in the hook payload.
    FygaroCheckout.create!(
      shop: @shop,
      cart_token: payload.fetch(:cart_token),
      custom_reference: custom_reference,
      customer: payload.fetch(:customer),
      shipping_address: payload.fetch(:shipping_address),
      shipping_rate: { handle: matching[:handle], title: matching[:title], price: matching[:price] },
      totals: totals,
      line_items: quote.line_items,
      total_amount: total_amount,
      currency: quote.totals[:currency],
      status: :pending
    )

    session = Fygaro::Gateway.create_session(
      cart_token: payload.fetch(:cart_token),
      custom_reference: custom_reference,
      customer: payload.fetch(:customer),
      shipping_address: payload.fetch(:shipping_address),
      shipping_rate: { handle: matching[:handle], title: matching[:title], price: matching[:price] },
      totals: totals,
      total_amount: total_amount,
      currency: quote.totals[:currency]
    )

    render json: { session_id: session.session_id, redirect_url: session.redirect_url }
  rescue KeyError => e
    render json: { error: "Missing field: #{e.key}" }, status: :bad_request
  rescue ArgumentError => e
    render json: { error: e.message }, status: :bad_request
  rescue Fygaro::Quote::CartNotFoundError, Fygaro::Quote::StorefrontAccessDenied,
         Fygaro::Quote::InvalidCountryError => e
    render json: { error: e.message }, status: :unprocessable_entity
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.record.errors.full_messages.join(", ") }, status: :unprocessable_entity
  rescue Fygaro::Gateway::NotConfigured => e
    render json: { error: e.message }, status: :service_unavailable
  rescue Fygaro::Gateway::Error => e
    render json: { error: e.message }, status: :bad_gateway
  end

  private

  def set_shop
    domain = params[:shop].to_s.downcase
    @shop = Shop.find_by(shopify_domain: domain) if domain.present?
    return if @shop

    render json: { error: "Unknown shop" }, status: :not_found
  end

  # Creates the per-shop storefront token on demand so the proxy endpoints work
  # even before the install-time job has run (or re-auth has happened). Failures
  # fall through so Fygaro::Quote raises the friendly 422.
  def ensure_storefront_token
    return if @shop.storefront_access_token.present?

    session = ShopifyApp::SessionRepository.retrieve_shop_session_by_shopify_domain(@shop.shopify_domain)
    Shops::StorefrontAccessToken.ensure!(shop: @shop, session: session) if session
  rescue StandardError
    nil
  end

  # Shopify App Proxy forwards the request body and appends its own query params
  # (shop/signature); parse the raw body so it never confuses the two.
  def payload
    @payload ||= JSON.parse(request.raw_post).deep_symbolize_keys
  rescue JSON::ParserError, TypeError
    {}
  end

  # Public API reached via Shopify's proxied fetcher, not a browser.
  def allow_browser(versions:, block:)
    nil
  end
end
