# frozen_string_literal: true

class FygaroCreateOrderJob < ApplicationJob
  queue_as :default

  retry_on Fygaro::OrderCreator::AdminAccessError, wait: 10.seconds, attempts: 5

  def perform(checkout_id)
    checkout = FygaroCheckout.find_by(id: checkout_id)
    return if checkout.nil?
    return unless checkout.paid?

    Fygaro::OrderCreator.call(checkout: checkout)
  rescue Fygaro::OrderCreator::AlreadyCreated
    nil
  end
end
