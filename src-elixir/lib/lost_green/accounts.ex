defmodule LostGreen.Accounts do
  @moduledoc """
  Context for managing local user profiles.

  Since this is a local-only application (no login), profiles are selected
  or created on the home screen rather than through authentication.
  """

  import Ecto.Query, warn: false

  alias LostGreen.Accounts.User
  alias LostGreen.Repo

  @doc "Returns all user profiles."
  def list_users do
    Repo.all(User)
  end

  @doc "Gets a single user by id. Raises if not found."
  def get_user!(id), do: Repo.get!(User, id)

  @doc "Gets a single user by id. Returns nil if not found."
  def get_user(id), do: Repo.get(User, id)

  @doc "Gets a user by their handle."
  def get_user_by_handle(handle) when is_binary(handle) do
    Repo.get_by(User, handle: handle)
  end

  @doc "Creates a user profile."
  def create_user(attrs \\ %{}) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Updates a user profile."
  def update_user(%User{} = user, attrs) do
    user
    |> User.changeset(attrs)
    |> Repo.update()
  end

  @doc "Deletes a user profile."
  def delete_user(%User{} = user) do
    Repo.delete(user)
  end

  @doc "Returns a changeset for tracking user profile changes."
  def change_user(%User{} = user, attrs \\ %{}) do
    User.changeset(user, attrs)
  end
end
