# frozen_string_literal: true

class FygaroCheckout < ApplicationRecord
  belongs_to :shop

  enum :status, { pending: 0, paid: 1, failed: 2 }

  validates :custom_reference, presence: true, uniqueness: true
  validates :cart_token, presence: true

  scope :pending, -> { where(status: :pending) }

  # Converts a Fygaro webhook customReference back to the matching checkout.
  def self.find_by_custom_reference(reference)
    find_by(custom_reference: reference)
  end
end
