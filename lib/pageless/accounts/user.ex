defmodule Pageless.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  alias Pageless.Accounts.{UserPermissions, UserLibrary}

  @roles ~w(admin user)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "users" do
    field :first_name, :string
    field :last_name, :string
    field :email, :string
    field :password, :string, virtual: true, redact: true
    field :hashed_password, :string, redact: true
    field :confirmed_at, :utc_datetime
    field :authenticated_at, :utc_datetime, virtual: true
    field :role, :string, default: "user"
    field :enabled, :boolean, default: true
    field :last_seen_at, :utc_datetime

    embeds_one :player_settings, Pageless.Accounts.PlayerSettings, on_replace: :update
    embeds_one :permissions, UserPermissions, on_replace: :update

    many_to_many :libraries, Pageless.Library.Library,
      join_through: UserLibrary,
      on_replace: :delete

    timestamps(type: :utc_datetime)
  end

  def roles, do: @roles

  @doc """
  Changeset for updating a user's player settings. `attrs` are the player
  settings params (e.g. `%{"jump_forward" => "10"}`).
  """
  def player_settings_changeset(user, attrs) do
    user
    |> ensure_player_settings()
    |> cast(%{"player_settings" => attrs}, [])
    |> cast_embed(:player_settings, required: true)
  end

  defp ensure_player_settings(%Pageless.Accounts.User{player_settings: nil} = user),
    do: %{user | player_settings: %Pageless.Accounts.PlayerSettings{}}

  defp ensure_player_settings(user), do: user

  defp ensure_permissions(%Pageless.Accounts.User{permissions: nil} = user),
    do: %{user | permissions: UserPermissions.defaults()}

  defp ensure_permissions(user), do: user

  @doc """
  Returns true if the user has the admin role.
  """
  def admin?(%Pageless.Accounts.User{role: "admin"}), do: true
  def admin?(_), do: false

  def enabled?(%Pageless.Accounts.User{enabled: true}), do: true
  def enabled?(_), do: false

  def display_name(%Pageless.Accounts.User{} = user) do
    [user.first_name, user.last_name]
    |> Enum.map(&String.trim(&1 || ""))
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> user.email
      names -> Enum.join(names, " ")
    end
  end

  def display_name(_), do: nil

  def permission_enabled?(%Pageless.Accounts.User{role: "admin"}, _permission), do: true

  def permission_enabled?(%Pageless.Accounts.User{} = user, permission)
      when permission in [
             :can_download,
             :can_update,
             :can_delete,
             :can_upload,
             :can_access_all_libraries
           ] do
    permissions = user.permissions || UserPermissions.defaults()
    Map.get(permissions, permission, false)
  end

  def permission_enabled?(_, _), do: false

  @doc """
  Changeset for accounts managed by an admin or the first-run setup flow.
  """
  def managed_changeset(user, attrs, opts \\ []) do
    user
    |> ensure_permissions()
    |> cast(attrs, [:first_name, :last_name, :email, :role, :enabled])
    |> validate_name_fields()
    |> validate_email(validate_change: false)
    |> validate_inclusion(:role, @roles)
    |> cast_embed(:permissions, required: true)
    |> maybe_put_default_permissions()
    |> maybe_validate_managed_password(attrs, opts)
  end

  defp maybe_put_default_permissions(changeset) do
    case get_field(changeset, :permissions) do
      nil -> put_embed(changeset, :permissions, UserPermissions.defaults())
      _permissions -> changeset
    end
  end

  defp maybe_validate_managed_password(changeset, attrs, opts) do
    password_required? = Keyword.get(opts, :password_required, false)
    password = Map.get(attrs, "password") || Map.get(attrs, :password)

    if password_required? || (is_binary(password) && password != "") do
      password_changeset(changeset, attrs)
    else
      changeset
    end
  end

  @doc """
  Changeset for user-editable profile details.
  """
  def profile_changeset(user, attrs) do
    user
    |> cast(attrs, [:first_name, :last_name])
    |> validate_name_fields()
  end

  defp validate_name_fields(changeset) do
    changeset
    |> update_change(:first_name, &trim_name/1)
    |> update_change(:last_name, &trim_name/1)
    |> validate_length(:first_name, max: 80)
    |> validate_length(:last_name, max: 80)
  end

  defp trim_name(nil), do: nil
  defp trim_name(name) when is_binary(name), do: String.trim(name)

  @doc """
  A user changeset for registering or changing the email.

  It requires the email to change otherwise an error is added.

  ## Options

    * `:validate_unique` - Set to false if you don't want to validate the
      uniqueness of the email, useful when displaying live validations.
      Defaults to `true`.
  """
  def email_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:email])
    |> validate_email(opts)
  end

  defp validate_email(changeset, opts) do
    changeset =
      changeset
      |> validate_required([:email])
      |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/,
        message: "must have the @ sign and no spaces"
      )
      |> validate_length(:email, max: 160)

    changeset =
      if Keyword.get(opts, :validate_unique, true) do
        changeset
        |> unsafe_validate_unique(:email, Pageless.Repo)
        |> unique_constraint(:email)
      else
        changeset
      end

    if Keyword.get(opts, :validate_change, true) do
      changeset
      |> validate_email_changed()
    else
      changeset
    end
  end

  defp validate_email_changed(changeset) do
    if get_field(changeset, :email) && get_change(changeset, :email) == nil do
      add_error(changeset, :email, "did not change")
    else
      changeset
    end
  end

  @doc """
  A user changeset for changing the password.

  It is important to validate the length of the password, as long passwords may
  be very expensive to hash for certain algorithms.

  ## Options

    * `:hash_password` - Hashes the password so it can be stored securely
      in the database and ensures the password field is cleared to prevent
      leaks in the logs. If password hashing is not needed and clearing the
      password field is not desired (like when using this changeset for
      validations on a LiveView form), this option can be set to `false`.
      Defaults to `true`.
  """
  def password_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:password])
    |> validate_confirmation(:password, message: "does not match password")
    |> validate_password(opts)
  end

  defp validate_password(changeset, opts) do
    changeset
    |> validate_required([:password])
    |> validate_length(:password, min: 12, max: 72)
    # Examples of additional password validation:
    # |> validate_format(:password, ~r/[a-z]/, message: "at least one lower case character")
    # |> validate_format(:password, ~r/[A-Z]/, message: "at least one upper case character")
    # |> validate_format(:password, ~r/[!?@#$%^&*_0-9]/, message: "at least one digit or punctuation character")
    |> maybe_hash_password(opts)
  end

  defp maybe_hash_password(changeset, opts) do
    hash_password? = Keyword.get(opts, :hash_password, true)
    password = get_change(changeset, :password)

    if hash_password? && password && changeset.valid? do
      changeset
      # If using Bcrypt, then further validate it is at most 72 bytes long
      |> validate_length(:password, max: 72, count: :bytes)
      # Hashing could be done with `Ecto.Changeset.prepare_changes/2`, but that
      # would keep the database transaction open longer and hurt performance.
      |> put_change(:hashed_password, Bcrypt.hash_pwd_salt(password))
      |> delete_change(:password)
    else
      changeset
    end
  end

  @doc """
  Confirms the account by setting `confirmed_at`.
  """
  def confirm_changeset(user) do
    now = DateTime.utc_now(:second)
    change(user, confirmed_at: now)
  end

  @doc """
  Verifies the password.

  If there is no user or the user doesn't have a password, we call
  `Bcrypt.no_user_verify/0` to avoid timing attacks.
  """
  def valid_password?(%Pageless.Accounts.User{hashed_password: hashed_password}, password)
      when is_binary(hashed_password) and byte_size(password) > 0 do
    Bcrypt.verify_pass(password, hashed_password)
  end

  def valid_password?(_, _) do
    Bcrypt.no_user_verify()
    false
  end
end
