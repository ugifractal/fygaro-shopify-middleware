# frozen_string_literal: true

require "test_helper"

class Api::Fygaro::HooksControllerTest < ActionDispatch::IntegrationTest
  setup do
    @api_key = "test-fygaro-key"
    @api_secret = "test-fygaro-secret"
    ENV["FYGARO_API_KEY"] = @api_key
    ENV["FYGARO_API_SECRET"] = @api_secret
    ENV["FIGARO_WEBHOOK_SECRET"] = @api_secret

    @shop = shops(:regular_shop)
    @checkout = FygaroCheckout.create!(
      shop: @shop,
      custom_reference: "a1b2c3d4e5f6a7b8c9d0",
      cart_token: "hWNGEGcVbnphZlhxyjGI1ym7V?key=430bcfc77927fa3d39ced69844a74ce0",
      status: :pending,
      customer: { email: "buyer@example.com" },
      shipping_address: { city: "Toronto", country: "Canada" },
      totals: { currency: "IDR", subtotal: 5000, discount: 0, total: 5000, shipping: 900 },
      line_items: [ { product_title: "Widget", quantity: 1 } ],
      total_amount: 5900,
      currency: "IDR"
    )
  end

  test "marks a pending checkout paid when the signature is valid" do
    assert_enqueued_with(job: FygaroCreateOrderJob, args: [ @checkout.id ]) do
      post_hooked(signature_for(good_webhook))
    end

    assert_response :success
    @checkout.reload
    assert @checkout.paid?
    assert_equal "08d7360a-fc4b-46ad-a513-0a3d3fd3771c", @checkout.fygaro_transaction_id
    assert_not_nil @checkout.paid_at
    assert_equal "59.99", @checkout.raw_payload["amount"]
  end

  test "rejects a webhook with a tampered body" do
    tampered = good_webhook.merge("amount" => "0.01")
    post_hooked(signature_for(good_webhook), body: tampered.to_json)

    assert_response :bad_request
    assert @checkout.reload.pending?, "checkout should remain pending"
  end

  test "rejects a webhook with an invalid signature" do
    post_hooked("deadbeef")

    assert_response :bad_request
    assert @checkout.reload.pending?
  end

  test "rejects a webhook for an unknown checkout" do
    unknown_body = good_webhook.merge("customReference" => "unknown-ref")
    post_hooked(signature_for(unknown_body), body: unknown_body.to_json)

    assert_response :not_found
  end

  test "is idempotent for a repeated transaction id" do
    post_hooked(signature_for(good_webhook))
    assert_response :success

    post_hooked(signature_for(good_webhook))
    assert_response :success
    @checkout.reload
    assert @checkout.paid?
  end

  test "rejects a webhook with a stale timestamp" do
    stale_ts = Time.now.to_i - 600
    stale = good_webhook
    post_hooked(signature_for(stale, ts: stale_ts), body: stale.to_json)

    assert_response :bad_request
  end

  private

  def good_webhook
    {
      "transactionId" => "08d7360a-fc4b-46ad-a513-0a3d3fd3771c",
      "reference" => "FYG-123",
      "customReference" => "a1b2c3d4e5f6a7b8c9d0",
      "authCode" => "A12345",
      "currency" => "USD",
      "amount" => "59.99",
      "createdAt" => "2026-08-31T14:32:07Z"
    }
  end

  def signature_for(body, ts: Time.now.to_i)
    raw = body.to_json
    { "timestamp" => ts, "v1" => OpenSSL::HMAC.hexdigest("SHA256", @api_secret, "#{ts}.#{raw}") }
  end

  def post_hooked(sig, body: good_webhook.to_json)
    ts = sig["timestamp"]
    headers = {
      "CONTENT_TYPE" => "application/json",
      "Fygaro-Key-ID" => @api_key,
      "Fygaro-Signature" => "t=#{ts},v1=#{sig["v1"]}"
    }
    post "/api/fygaro/hooks", params: body, headers: headers
  end
end
