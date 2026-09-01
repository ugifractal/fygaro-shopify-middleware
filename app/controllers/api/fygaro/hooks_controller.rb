# frozen_string_literal: true

class Api::Fygaro::HooksController < ApplicationController
  skip_forgery_protection

  # Receives Fygaro Payment-Button Hook notifications after a successful
  # payment. Validates the HMAC signature, correlates the payment back to the
  # pending FygaroCheckout via custom_reference, marks it paid, and enqueues a
  # job that creates the Shopify Order via orderCreate from the snapshot.
  def create
    raw = request.raw_post
    key_id = request.headers["Fygaro-Key-ID"]
    signature_header = request.headers["Fygaro-Signature"]

    unless valid_signature?(raw, key_id, signature_header)
      return render json: { error: "Invalid signature" }, status: :bad_request
    end

    payload = JSON.parse(raw)
    checkout = FygaroCheckout.find_by_custom_reference(payload["customReference"])

    unless checkout
      return render json: { error: "Unknown checkout" }, status: :not_found
    end

    checkout.update!(
      fygaro_transaction_id: payload["transactionId"],
      status: :paid,
      paid_at: payload["createdAt"],
      raw_payload: payload
    )

    FygaroCreateOrderJob.perform_later(checkout.id)

    head :ok
  rescue JSON::ParserError
    render json: { error: "Invalid JSON" }, status: :bad_request
  end

  private

  def valid_signature?(raw, key_id, signature_header)
    timestamp, hashes = parse_signature_header(signature_header)
    return false if timestamp.nil? || hashes.empty?
    return false if (Time.now.to_i - timestamp).abs > 300

    secret = webhook_secret_for(key_id)
    return false if secret.blank?

    expected = OpenSSL::HMAC.hexdigest("SHA256", secret, "#{timestamp}.#{raw}")
    hashes.any? { |hash| ActiveSupport::SecurityUtils.secure_compare(expected, hash) }
  end

  def parse_signature_header(header)
    return [ nil, [] ] if header.blank?

    timestamp = nil
    hashes = []
    header.to_s.split(",").each do |part|
      key, value = part.strip.split("=", 2)
      timestamp = value.to_i if key == "t"
      hashes << value if key == "v1"
    end
    [ timestamp, hashes ]
  end

  # Fygaro signs hooks with the API secret keyed by Fygaro-Key-ID (the API key
  # used in the payment JWT). FYGARO_WEBHOOK_SECRET can be set as an explicit
  # alias equal to FYGARO_API_SECRET for wiring explicitness.
  def webhook_secret_for(key_id)
    return ENV["FYGARO_API_SECRET"] if key_id == ENV["FYGARO_API_KEY"]

    ENV["FYGARO_API_SECRET"] if key_id == ENV["FYGARO_WEBHOOK_SECRET"]
  end
end
