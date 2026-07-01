defmodule Pageless.Accounts.PlayerSettings do
  @moduledoc """
  Per-user player and display preferences, persisted as a jsonb column on `users`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @jump_amounts [5, 10, 15, 20, 30, 60]
  @rate_increments [0.1, 0.25, 0.5]
  @cover_size_min 120
  @cover_size_max 360
  @cover_size_default 180
  @date_formats [
    {"MM/DD/YYYY", "MM/dd/yyyy"},
    {"DD/MM/YYYY", "dd/MM/yyyy"},
    {"DD.MM.YYYY", "dd.MM.yyyy"},
    {"YYYY-MM-DD", "yyyy-MM-dd"},
    {"MMM do, yyyy", "MMM do, yyyy"},
    {"MMMM do, yyyy", "MMMM do, yyyy"},
    {"dd MMM yyyy", "dd MMM yyyy"},
    {"dd MMMM yyyy", "dd MMMM yyyy"}
  ]
  @time_formats [{"h:mma (am/pm)", "h:mma"}, {"HH:mm (24-hour)", "HH:mm"}]
  @date_format_default "dd/MM/yyyy"
  @time_format_default "HH:mm"

  @primary_key false
  embedded_schema do
    field :use_chapter_track, :boolean, default: true
    field :jump_forward, :integer, default: 30
    field :jump_backward, :integer, default: 15
    field :rate_increment, :float, default: 0.1
    field :playback_rate, :float, default: 1.0
    field :cover_size, :integer, default: @cover_size_default
    field :ignore_prefixes_when_sorting, :boolean, default: false
    field :date_format, :string, default: @date_format_default
    field :time_format, :string, default: @time_format_default
  end

  @doc false
  def changeset(settings, attrs) do
    settings
    |> cast(attrs, [
      :use_chapter_track,
      :jump_forward,
      :jump_backward,
      :rate_increment,
      :playback_rate,
      :cover_size,
      :ignore_prefixes_when_sorting,
      :date_format,
      :time_format
    ])
    |> validate_inclusion(:jump_forward, @jump_amounts)
    |> validate_inclusion(:jump_backward, @jump_amounts)
    |> validate_inclusion(:rate_increment, @rate_increments)
    |> validate_number(:playback_rate, greater_than_or_equal_to: 0.5, less_than_or_equal_to: 3.0)
    |> validate_number(:cover_size,
      greater_than_or_equal_to: @cover_size_min,
      less_than_or_equal_to: @cover_size_max
    )
    |> validate_inclusion(:date_format, Enum.map(@date_formats, &elem(&1, 1)))
    |> validate_inclusion(:time_format, Enum.map(@time_formats, &elem(&1, 1)))
  end

  def jump_amounts, do: @jump_amounts
  def rate_increments, do: @rate_increments
  def cover_size_min, do: @cover_size_min
  def cover_size_max, do: @cover_size_max
  def cover_size_default, do: @cover_size_default
  def date_formats, do: @date_formats
  def time_formats, do: @time_formats
  def date_format_default, do: @date_format_default
  def time_format_default, do: @time_format_default
end
