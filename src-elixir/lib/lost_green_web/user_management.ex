defmodule LostGreenWeb.UserManagement do
  @moduledoc false

  import Plug.Conn

  alias LostGreen.Accounts
  alias LostGreen.Metrics

  # Plug behaviour so this module can be used as `plug LostGreenWeb.UserManagement, :action`
  def init(action), do: action
  def call(conn, :fetch_current_user), do: fetch_current_user(conn, [])

  # ── Plug ──────────────────────────────────────────────────────────────────

  def fetch_current_user(conn, _opts) do
    user_id = get_session(conn, :current_user_id)
    user = user_id && Accounts.get_user(user_id)
    assign(conn, :current_user, user)
  end

  def log_in_user(conn, user) do
    Metrics.stop_all()

    conn
    |> renew_session()
    |> put_session(:current_user_id, user.id)
  end

  def log_out_user(conn) do
    Metrics.stop_all()

    conn
    |> renew_session()
    |> delete_session(:current_user_id)
  end

  defp renew_session(conn) do
    configure_session(conn, renew: true)
  end

  # ── LiveView on_mount ─────────────────────────────────────────────────────

  def on_mount(:require_current_user, _params, session, socket) do
    socket = mount_current_user(session, socket)

    case socket.assigns[:current_user] do
      nil ->
        socket =
          socket
          |> Phoenix.LiveView.put_flash(:error, "Select a profile to continue.")
          |> Phoenix.LiveView.redirect(to: "/")

        {:halt, socket}

      _user ->
        {:cont, socket}
    end
  end

  defp mount_current_user(session, socket) do
    Phoenix.Component.assign_new(socket, :current_user, fn ->
      user_id = Map.get(session, "current_user_id")
      user_id && Accounts.get_user(user_id)
    end)
  end
end
