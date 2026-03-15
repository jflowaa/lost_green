defmodule LostGreen.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :handle, :string, null: false
      add :gender, :string, null: false
      add :birthdate, :date, null: false
      add :height, :float, null: false
      add :weight, :float, null: false
      add :measurement_units, :string, null: false, default: "metric"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:users, [:handle])
    create index(:users, [:id])
  end
end
