defmodule LostGreenWeb.PageController do
  use LostGreenWeb, :controller

  alias LostGreen.Accounts
  alias LostGreenWeb.UserManagement

  def home(conn, _params) do
    app_name = application_name()
    users = Accounts.list_users()
    form = Phoenix.Component.to_form(Accounts.change_user(%Accounts.User{}), as: :user)

    render(conn, :home,
      app_name: app_name,
      page_title: app_name,
      users: users,
      form: form
    )
  end

  def favicon(conn, _params) do
    redirect(conn, to: "/favicon.svg")
  end

  # Select an existing user profile and go to the dashboard.
  def select_user(conn, %{"user_id" => user_id}) do
    case Accounts.get_user(user_id) do
      nil ->
        conn
        |> put_flash(:error, "Profile not found.")
        |> redirect(to: ~p"/")

      user ->
        conn
        |> UserManagement.log_in_user(user)
        |> redirect(to: ~p"/dashboard")
    end
  end

  # Create a new user profile and immediately select it.
  def create_user(conn, %{"user" => user_params}) do
    case Accounts.create_user(user_params) do
      {:ok, user} ->
        conn
        |> put_flash(:info, "Profile created!")
        |> UserManagement.log_in_user(user)
        |> redirect(to: ~p"/dashboard")

      {:error, changeset} ->
        app_name = application_name()
        users = Accounts.list_users()
        form = Phoenix.Component.to_form(changeset, as: :user)

        conn
        |> put_flash(:error, "Please fix the errors below.")
        |> render(:home,
          app_name: app_name,
          page_title: app_name,
          users: users,
          form: form
        )
    end
  end

  # Show the profile edit form for the currently-logged-in user.
  def edit_profile(conn, _params) do
    case conn.assigns[:current_user] do
      nil ->
        conn
        |> put_flash(:error, "Select a profile first.")
        |> redirect(to: ~p"/")

      user ->
        form = Phoenix.Component.to_form(Accounts.change_user(user), as: :user)
        render(conn, :edit_profile, page_title: "Edit Profile", form: form, user: user)
    end
  end

  # Process the profile update form submission.
  def update_profile(conn, %{"user" => user_params}) do
    case conn.assigns[:current_user] do
      nil ->
        conn
        |> put_flash(:error, "Select a profile first.")
        |> redirect(to: ~p"/")

      user ->
        case Accounts.update_user(user, user_params) do
          {:ok, _updated_user} ->
            conn
            |> put_flash(:info, "Profile updated.")
            |> redirect(to: ~p"/dashboard")

          {:error, changeset} ->
            form = Phoenix.Component.to_form(changeset, as: :user)

            conn
            |> put_flash(:error, "Please fix the errors below.")
            |> render(:edit_profile, page_title: "Edit Profile", form: form, user: user)
        end
    end
  end

  # Clear the session and return to the profile selector.
  def logout(conn, _params) do
    conn
    |> UserManagement.log_out_user()
    |> redirect(to: ~p"/")
  end

  defp application_name do
    Application.get_env(:lost_green, :application_name, "Lost Green")
  end
end
