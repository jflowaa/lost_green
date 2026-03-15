defmodule LostGreen.Repo do
  use Ecto.Repo,
    otp_app: :lost_green,
    adapter: Ecto.Adapters.SQLite3
end
