defmodule Pageless.Accounts.UserPermissions do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :can_download, :boolean, default: true
    field :can_update, :boolean, default: false
    field :can_delete, :boolean, default: false
    field :can_upload, :boolean, default: false
    field :can_access_all_libraries, :boolean, default: true
  end

  @fields ~w(can_download can_update can_delete can_upload can_access_all_libraries)a

  def fields, do: @fields

  def defaults do
    %__MODULE__{}
  end

  def admin_defaults do
    %__MODULE__{
      can_download: true,
      can_update: true,
      can_delete: true,
      can_upload: true,
      can_access_all_libraries: true
    }
  end

  def changeset(permissions, attrs) do
    permissions
    |> cast(attrs, @fields)
    |> validate_required(@fields)
  end
end
