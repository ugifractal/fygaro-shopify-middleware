# frozen_string_literal: true

module Fygaro
  # Converts the Shopify cart totals (in the store's money, IDR) to the
  # currency Fygaro can charge (USD) using the `money` gem backed by ECB rates.
  #
  # ECB rates (EUR base) are the primary source; if they aren't available yet
  # (fresh boot before the refresh job has cached rates, or network down) it
  # falls back to the manually-seeded FYGARO_IDR_TO_USD_RATE so checkout never
  # blocks on FX.
  module Fx
    CACHE_PATH = Rails.root.join("tmp", "fx", "ecb_rates.xml")
    FALLBACK_RATE_VAR = "FYGARO_IDR_TO_USD_RATE"

    module_function

    # Converts an IDR minor-unit amount (e.g. 10145800) into USD minor units.
    def idr_to_usd_minor(idr_minor)
      ::Money.new(idr_minor, "IDR").exchange_to("USD").cents
    rescue ::Money::Bank::UnknownRate, CurrencyUnavailable
      fallback_idr_to_usd_minor(idr_minor)
    end

    # Sets up the process-wide exchange bank. Safe to call at boot: loading a
    # cached ECB file is optional and never blocks.
    def configure_default_bank!
      ::Money.default_bank = EuCentralBank.new
      load_cached_rates!
    end

    # Fetches fresh ECB rates, caches the raw XML so other workers/boots can
    # load them without a network call, and loads them into the current process.
    def refresh_rates!
      FileUtils.mkdir_p(File.dirname(CACHE_PATH))
      ::Money.default_bank.save_rates(CACHE_PATH)
      ::Money.default_bank.update_rates(CACHE_PATH)
    rescue StandardError => e
      Rails.logger.warn("Fygaro::Fx failed to refresh ECB rates: #{e.class}: #{e.message}")
      nil
    end

    def load_cached_rates!
      return unless File.file?(CACHE_PATH)

      ::Money.default_bank.update_rates(CACHE_PATH)
    rescue StandardError => e
      Rails.logger.warn("Fygaro::Fx failed to load cached ECB rates: #{e.class}: #{e.message}")
      nil
    end

    def fallback_idr_to_usd_minor(idr_minor)
      rate = ENV[FALLBACK_RATE_VAR]
      raise Fygaro::Gateway::NotConfigured,
            "#{FALLBACK_RATE_VAR} is not configured and ECB rates are unavailable" if rate.blank?

      idr_decimal = idr_minor / 100.0
      (idr_decimal / BigDecimal(rate.to_s) * 100).round
    end
  end
end
