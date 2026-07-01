defmodule Pageless.Library.AudioFile do
  use Ecto.Schema
  import Ecto.Changeset

  alias Pageless.Library.Book

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "audio_files" do
    field :path, :string
    field :index, :integer, default: 0
    field :duration_seconds, :float, default: 0.0
    field :codec, :string
    field :bitrate, :integer
    field :mime_type, :string
    field :size, :integer

    belongs_to :book, Book

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(audio_file, attrs) do
    audio_file
    |> cast(attrs, [:path, :index, :duration_seconds, :codec, :bitrate, :mime_type, :size])
    |> validate_required([:path, :index, :duration_seconds])
  end
end
