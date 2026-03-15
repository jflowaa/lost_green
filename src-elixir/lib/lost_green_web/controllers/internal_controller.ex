defmodule LostGreenWeb.InternalController do
  use LostGreenWeb, :controller

  def shutdown(conn, _params) do
    expected_token = System.get_env("BACKEND_SHUTDOWN_TOKEN")

    provided_token =
      conn
      |> get_req_header("x-backend-shutdown-token")
      |> List.first()

    cond do
      System.get_env("RUNNING_UNDER_TAURI") != "true" ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "shutdown disabled"})

      is_nil(expected_token) or expected_token == "" ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "shutdown token not configured"})

      provided_token != expected_token ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "invalid shutdown token"})

      true ->
        Task.start(fn ->
          Process.sleep(100)
          System.stop(0)
        end)

        json(conn, %{ok: true})
    end
  end
end
