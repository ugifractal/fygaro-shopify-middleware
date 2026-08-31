# frozen_string_literal: true

class FygaroRefreshFxJob < ApplicationJob
  queue_as :default

  def perform
    Fygaro::Fx.refresh_rates!
  end
end
