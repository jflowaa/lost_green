defmodule LostGreenWeb.PageControllerTest do
  use LostGreenWeb.ConnCase

  alias LostGreen.Accounts

  test "GET /", %{conn: conn} do
    app_name = Application.get_env(:lost_green, :application_name)

    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    assert html =~ app_name
    assert html =~ "Create your first profile"
    assert html =~ "Create Profile"
  end

  test "GET / shows existing profiles when present", %{conn: conn} do
    {:ok, _user} =
      Accounts.create_user(%{
        "handle" => "Jack",
        "gender" => "male",
        "birthdate" => "1990-05-15",
        "height" => "70",
        "weight" => "160",
        "measurement_units" => "imperial"
      })

    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    assert html =~ "Who's riding today?"
    assert html =~ "Jack"
    assert html =~ "New Profile"
  end

  test "POST /users creates a profile and logs it in", %{conn: conn} do
    conn =
      post(conn, ~p"/users", %{
        "user" => %{
          "handle" => "NewRider",
          "gender" => "male",
          "birthdate" => "1990-05-15",
          "measurement_units" => "metric",
          "height" => "180",
          "weight" => "75"
        }
      })

    assert redirected_to(conn) == ~p"/dashboard"
    assert get_session(conn, :current_user_id)
  end

  test "POST /users with invalid data re-renders the form", %{conn: conn} do
    conn = post(conn, ~p"/users", %{"user" => %{"handle" => "", "measurement_units" => ""}})

    html = html_response(conn, 200)

    assert html =~ "Please fix the errors below."
    assert html =~ "Create Profile"
  end

  test "POST /users/select logs in the chosen profile", %{conn: conn} do
    {:ok, user} =
      Accounts.create_user(%{
        "handle" => "Selector",
        "gender" => "female",
        "birthdate" => "1995-03-20",
        "height" => "65",
        "weight" => "130",
        "measurement_units" => "imperial"
      })

    conn = post(conn, ~p"/users/select", %{"user_id" => user.id})

    assert redirected_to(conn) == ~p"/dashboard"
    assert get_session(conn, :current_user_id) == user.id
  end

  test "POST /users/select with unknown profile redirects home with error", %{conn: conn} do
    conn = post(conn, ~p"/users/select", %{"user_id" => Ecto.UUID.generate()})

    assert redirected_to(conn) == ~p"/"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Profile not found."
  end

  test "DELETE /logout clears session and redirects home", %{conn: conn} do
    {:ok, user} =
      Accounts.create_user(%{
        "handle" => "LogoutRider",
        "gender" => "male",
        "birthdate" => "1988-11-10",
        "height" => "72",
        "weight" => "185",
        "measurement_units" => "imperial"
      })

    conn =
      conn
      |> Plug.Test.init_test_session(%{current_user_id: user.id})
      |> delete(~p"/logout")

    assert redirected_to(conn) == ~p"/"
    refute get_session(conn, :current_user_id)
  end

  defp create_full_user(handle) do
    {:ok, user} =
      Accounts.create_user(%{
        "handle" => handle,
        "gender" => "male",
        "birthdate" => "1990-01-01",
        "height" => "70",
        "weight" => "160",
        "measurement_units" => "imperial"
      })

    user
  end

  test "GET /profile/edit redirects to home when not logged in", %{conn: conn} do
    conn = get(conn, ~p"/profile/edit")

    assert redirected_to(conn) == ~p"/"
  end

  test "GET /profile/edit renders the edit form for the current user", %{conn: conn} do
    user = create_full_user("EditRider")

    conn =
      conn
      |> Plug.Test.init_test_session(%{current_user_id: user.id})
      |> get(~p"/profile/edit")

    html = html_response(conn, 200)

    assert html =~ "Edit Profile"
    assert html =~ "EditRider"
    assert html =~ "Save Changes"
  end

  test "PUT /profile updates the user and redirects to dashboard", %{conn: conn} do
    user = create_full_user("UpdateRider")

    conn =
      conn
      |> Plug.Test.init_test_session(%{current_user_id: user.id})
      |> put(~p"/profile", %{
        "user" => %{
          "handle" => "UpdateRider",
          "gender" => "male",
          "birthdate" => "1990-01-01",
          "height" => "71",
          "weight" => "155",
          "measurement_units" => "metric"
        }
      })

    assert redirected_to(conn) == ~p"/dashboard"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Profile updated."
    assert Accounts.get_user(user.id).weight == 155
  end

  test "PUT /profile with invalid data re-renders the edit form", %{conn: conn} do
    user = create_full_user("BadUpdateRider")

    conn =
      conn
      |> Plug.Test.init_test_session(%{current_user_id: user.id})
      |> put(~p"/profile", %{"user" => %{"handle" => "", "measurement_units" => ""}})

    html = html_response(conn, 200)

    assert html =~ "Please fix the errors below."
    assert html =~ "Edit Profile"
  end
end
