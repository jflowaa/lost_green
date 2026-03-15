defmodule LostGreen.Accounts.User do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @measurement_units ~w(imperial metric)
  @genders ~w(male female)

  schema "users" do
    field :handle, :string
    field :gender, :string
    field :birthdate, :date
    field :height, :float
    field :weight, :float
    field :measurement_units, :string, default: "metric"

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating a user profile.

  Height and weight are stored in the units indicated by `measurement_units`:
    - imperial: height in inches, weight in pounds
    - metric: height in centimeters, weight in kilograms
  """
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:handle, :gender, :birthdate, :height, :weight, :measurement_units])
    |> validate_required([:handle, :measurement_units, :gender, :birthdate, :height, :weight])
    |> validate_length(:handle, min: 2, max: 50)
    |> validate_format(:handle, ~r/^[a-zA-Z0-9_-]+$/,
      message: "only letters, numbers, underscores and hyphens allowed"
    )
    |> validate_inclusion(:measurement_units, @measurement_units)
    |> validate_inclusion(:gender, @genders)
    |> validate_number(:height, greater_than: 0)
    |> validate_number(:weight, greater_than: 0)
    |> unique_constraint(:handle)
  end
end
