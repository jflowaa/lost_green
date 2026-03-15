import Config

# Print only warnings and errors during test
config :logger, level: :warning

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used

# In test we don't send emails
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :lost_green, LostGreen.Mailer, adapter: Swoosh.Adapters.Test

config :lost_green, LostGreen.Repo,
  database: Path.expand("../lost_green_test.db", __DIR__),
  # We don't run a server during test. If one is required,
  # you can enable the server option below.
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

config :lost_green, LostGreenWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "e3/SYUK0IGINkl6hqeNhc29GleyuWRNabnW9Ybj5mLO8IgNuv38PGO8H40hAxkMP",
  server: false

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false
