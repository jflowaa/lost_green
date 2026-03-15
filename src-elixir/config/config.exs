# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  lost_green: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :lost_green, LostGreen.Mailer, adapter: Swoosh.Adapters.Local

# Configure the endpoint
config :lost_green, LostGreenWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: LostGreenWeb.ErrorHTML, json: LostGreenWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: LostGreen.PubSub,
  live_view: [signing_salt: "nxfCvgKN"]

config :lost_green,
  application_name: "Bike Potato",
  auth_email_cooldown_seconds: 60,
  auth_magic_link_ttl_seconds: 300,
  auth_magic_link_cleanup_interval_seconds: 600,
  ecto_repos: [LostGreen.Repo],
  generators: [timestamp_type: :utc_datetime]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  lost_green: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),

    # Import environment specific config. This must remain at the bottom
    # of this file so it overrides the configuration defined above.
    cd: Path.expand("..", __DIR__)
  ]

import_config "#{config_env()}.exs"
