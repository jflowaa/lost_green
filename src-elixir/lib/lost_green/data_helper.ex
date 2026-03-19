defmodule LostGreen.DataHelper do
  @moduledoc """
  Normalizes data coming from various sources (e.g. different devices, APIs, etc.) into a consistent format for easier processing and display in the dashboard
  """

  def normalize_device(attrs),
    do: %{
      id: Map.get(attrs, "id"),
      name: Map.get(attrs, "name") || "Unknown Device",
      connected_at: System.system_time(:millisecond)
    }

  def normalize_profile(profile) do
    gender = parse_gender(Map.get(profile, :gender))
    weight = Map.get(profile, :weight)
    units = Map.get(profile, :measurement_units)
    weight_kg = Map.get(profile, :weight_kg, to_weight_kg(weight, units))
    birthdate = Map.get(profile, :birthdate)
    age = Map.get(profile, :age, age_from_birthdate(birthdate))
    %{age: age, weight_kg: weight_kg, gender: gender}
  end

  def parse_gender("male"), do: :male
  def parse_gender("female"), do: :female
  def parse_gender(:male), do: :male
  def parse_gender(:female), do: :female
  def parse_gender(_), do: nil

  def to_weight_kg(nil, _units), do: nil
  def to_weight_kg(weight, "imperial"), do: weight * 0.453592
  def to_weight_kg(weight, _), do: weight * 1.0

  def age_from_birthdate(nil), do: nil

  def age_from_birthdate(%Date{} = birthdate) do
    today = Date.utc_today()
    years = today.year - birthdate.year
    if {today.month, today.day} < {birthdate.month, birthdate.day}, do: years - 1, else: years
  end

  def age_from_birthdate(date_string) when is_binary(date_string) do
    case Date.from_iso8601(date_string) do
      {:ok, date} -> age_from_birthdate(date)
      _ -> nil
    end
  end

  def age_from_birthdate(_), do: nil

  def normalize_int(value) when is_integer(value), do: value
  def normalize_int(value) when is_float(value), do: round(value)

  def normalize_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _} -> parsed
      :error -> raise ArgumentError, "heart rate must be numeric"
    end
  end

  def normalize_timestamp(metadata),
    do: Map.get(metadata, "at", System.system_time(:millisecond)) |> normalize_int()
end
