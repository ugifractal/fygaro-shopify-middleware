# frozen_string_literal: true

require_dependency "fygaro/fx"

# Set up the `money` gem's currency bank (ECB rates + offline fallback) at boot
# so Fygaro checkout can convert IDR totals to USD without blocking on FX.
Fygaro::Fx.configure_default_bank!
