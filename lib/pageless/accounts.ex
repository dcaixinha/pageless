defmodule Pageless.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias Pageless.Repo

  alias Pageless.Accounts.{Scope, User, UserLibrary, UserNotifier, UserPermissions, UserToken}

  ## Database getters

  @doc """
  Gets a user by email.

  ## Examples

      iex> get_user_by_email("foo@example.com")
      %User{}

      iex> get_user_by_email("unknown@example.com")
      nil

  """
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email)
  end

  @doc """
  Gets a user by email and password.

  ## Examples

      iex> get_user_by_email_and_password("foo@example.com", "correct_password")
      %User{}

      iex> get_user_by_email_and_password("foo@example.com", "invalid_password")
      nil

  """
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = Repo.get_by(User, email: email)
    if User.enabled?(user) && User.valid_password?(user, password), do: user
  end

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user!(id), do: Repo.get!(User, id)

  @doc """
  Returns true when at least one account exists.
  """
  def any_users? do
    Repo.exists?(User)
  end

  @doc """
  Lists users for the admin settings UI.
  """
  def list_users(%Scope{user: %User{} = actor}) do
    true = User.admin?(actor)

    User
    |> order_by(asc: :email)
    |> preload(:libraries)
    |> Repo.all()
  end

  @doc """
  Gets a user for admin management.
  """
  def get_managed_user!(%Scope{user: %User{} = actor}, id) do
    true = User.admin?(actor)

    User
    |> preload(:libraries)
    |> Repo.get!(id)
  end

  @doc """
  Returns a changeset for admin-managed users.
  """
  def change_managed_user(%Scope{user: %User{} = actor}, %User{} = user, attrs \\ %{}) do
    true = User.admin?(actor)
    User.managed_changeset(user, attrs, password_required: false)
  end

  def change_user_profile(%User{} = user, attrs \\ %{}) do
    User.profile_changeset(user, attrs)
  end

  def update_user_profile(%User{} = user, attrs) do
    user
    |> User.profile_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Creates the first admin account. This only succeeds while no users exist.
  """
  def create_initial_admin(attrs) do
    Repo.transact(fn ->
      if any_users?() do
        {:error, :already_setup}
      else
        attrs =
          attrs
          |> stringify_keys()
          |> Map.merge(%{
            "role" => "admin",
            "enabled" => true,
            "permissions" => permissions_params(UserPermissions.admin_defaults())
          })

        %User{confirmed_at: DateTime.utc_now(:second)}
        |> User.managed_changeset(attrs, password_required: true)
        |> Repo.insert()
      end
    end)
  end

  @doc """
  Creates a user from the admin settings UI.
  """
  def create_managed_user(%Scope{user: %User{} = actor}, attrs) do
    true = User.admin?(actor)

    Repo.transact(fn ->
      attrs = stringify_keys(attrs)
      {library_ids, attrs} = Map.pop(attrs, "library_ids", [])

      changeset =
        %User{confirmed_at: DateTime.utc_now(:second)}
        |> User.managed_changeset(attrs, password_required: true)

      with {:ok, user} <- Repo.insert(changeset),
           :ok <- replace_user_libraries(user, library_ids) do
        {:ok, Repo.preload(user, :libraries)}
      end
    end)
  end

  @doc """
  Updates a user from the admin settings UI.
  """
  def update_managed_user(%Scope{user: %User{} = actor}, %User{} = user, attrs) do
    true = User.admin?(actor)

    Repo.transact(fn ->
      attrs = stringify_keys(attrs)
      {library_ids, attrs} = Map.pop(attrs, "library_ids", [])
      changeset = User.managed_changeset(user, attrs, password_required: false)

      with :ok <- validate_admin_safety(actor, user, changeset),
           {:ok, user} <- Repo.update(changeset),
           :ok <- replace_user_libraries(user, library_ids) do
        {:ok, Repo.preload(user, :libraries)}
      end
    end)
  end

  @doc """
  Deletes a managed user unless doing so would remove the last enabled admin.
  """
  def delete_managed_user(%Scope{user: %User{} = actor}, %User{} = user) do
    true = User.admin?(actor)

    cond do
      actor.id == user.id ->
        {:error, :cannot_delete_self}

      last_enabled_admin?(user) ->
        {:error, :last_admin}

      true ->
        Repo.delete(user)
    end
  end

  def user_can?(%User{} = user, permission),
    do: User.enabled?(user) && User.permission_enabled?(user, permission)

  def user_can?(_, _), do: false

  def user_can_access_library?(%User{} = user, library_id) do
    cond do
      not User.enabled?(user) ->
        false

      User.admin?(user) ->
        true

      User.permission_enabled?(user, :can_access_all_libraries) ->
        true

      is_nil(library_id) ->
        false

      true ->
        Repo.exists?(
          from ul in UserLibrary, where: ul.user_id == ^user.id and ul.library_id == ^library_id
        )
    end
  end

  def user_can_access_library?(_, _), do: false

  def accessible_library_ids(%Scope{user: %User{} = user}) do
    cond do
      not User.enabled?(user) ->
        []

      User.admin?(user) or User.permission_enabled?(user, :can_access_all_libraries) ->
        :all

      true ->
        Repo.all(from ul in UserLibrary, where: ul.user_id == ^user.id, select: ul.library_id)
    end
  end

  def accessible_library_ids(_), do: []

  ## User registration

  @doc """
  Registers a user.

  ## Examples

      iex> register_user(%{field: value})
      {:ok, %User{}}

      iex> register_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def register_user(attrs) do
    %User{}
    |> User.email_changeset(attrs)
    |> Repo.insert()
  end

  defp validate_admin_safety(actor, user, changeset) do
    role = Ecto.Changeset.get_field(changeset, :role)
    enabled = Ecto.Changeset.get_field(changeset, :enabled)

    cond do
      actor.id == user.id && enabled == false ->
        {:error, :cannot_disable_self}

      last_enabled_admin?(user) && (role != "admin" or enabled == false) ->
        {:error, :last_admin}

      true ->
        :ok
    end
  end

  defp last_enabled_admin?(%User{role: "admin", enabled: true, id: id}) do
    not Repo.exists?(
      from u in User,
        where: u.id != ^id and u.role == "admin" and u.enabled == true
    )
  end

  defp last_enabled_admin?(_), do: false

  defp replace_user_libraries(%User{} = user, library_ids) do
    Repo.delete_all(from ul in UserLibrary, where: ul.user_id == ^user.id)

    library_ids =
      library_ids
      |> List.wrap()
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()

    now = DateTime.utc_now(:second)

    rows =
      Enum.map(library_ids, fn library_id ->
        %{
          id: Ecto.UUID.generate(),
          user_id: user.id,
          library_id: library_id,
          inserted_at: now,
          updated_at: now
        }
      end)

    if rows != [] do
      Repo.insert_all(UserLibrary, rows)
    end

    :ok
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), stringify_value(value)}
      {key, value} -> {key, stringify_value(value)}
    end)
  end

  defp stringify_value(value) when is_map(value), do: stringify_keys(value)
  defp stringify_value(value), do: value

  defp permissions_params(%UserPermissions{} = permissions) do
    permissions
    |> Map.from_struct()
    |> Map.delete(:__meta__)
    |> stringify_keys()
  end

  ## Settings

  @doc """
  Checks whether the user is in sudo mode.

  The user is in sudo mode when the last authentication was done no further
  than 20 minutes ago. The limit can be given as second argument in minutes.
  """
  def sudo_mode?(user, minutes \\ -20)

  def sudo_mode?(%User{authenticated_at: ts}, minutes) when is_struct(ts, DateTime) do
    DateTime.after?(ts, DateTime.utc_now() |> DateTime.add(minutes, :minute))
  end

  def sudo_mode?(_user, _minutes), do: false

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user email.

  See `Pageless.Accounts.User.email_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_email(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_email(user, attrs \\ %{}, opts \\ []) do
    User.email_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user email using the given token.

  If the token matches, the user email is updated and the token is deleted.
  """
  def update_user_email(user, token) do
    context = "change:#{user.email}"

    Repo.transact(fn ->
      with {:ok, query} <- UserToken.verify_change_email_token_query(token, context),
           %UserToken{sent_to: email} <- Repo.one(query),
           {:ok, user} <- Repo.update(User.email_changeset(user, %{email: email})),
           {_count, _result} <-
             Repo.delete_all(from(UserToken, where: [user_id: ^user.id, context: ^context])) do
        {:ok, user}
      else
        _ -> {:error, :transaction_aborted}
      end
    end)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user password.

  See `Pageless.Accounts.User.password_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_password(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_password(user, attrs \\ %{}, opts \\ []) do
    User.password_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user password.

  Returns a tuple with the updated user, as well as a list of expired tokens.

  ## Examples

      iex> update_user_password(user, %{password: ...})
      {:ok, {%User{}, [...]}}

      iex> update_user_password(user, %{password: "too short"})
      {:error, %Ecto.Changeset{}}

  """
  def update_user_password(user, attrs) do
    user
    |> User.password_changeset(attrs)
    |> update_user_and_delete_all_tokens()
  end

  ## Session

  @doc """
  Generates a session token.
  """
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Gets the user with the given signed token.

  If the token is valid `{user, token_inserted_at}` is returned, otherwise `nil` is returned.
  """
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)

    case Repo.one(query) do
      {%User{} = user, token_inserted_at} ->
        touch_user_seen(user)
        {user, token_inserted_at}

      nil ->
        nil
    end
  end

  ## API tokens

  @doc """
  Authenticates a user by email and password and issues a long-lived API token
  for the named device.

  Returns `{:ok, {token, user}}` on success or `{:error, :invalid_credentials}`.
  """
  def create_api_token(email, password, device_name)
      when is_binary(email) and is_binary(password) do
    case get_user_by_email_and_password(email, password) do
      %User{} = user ->
        {token, user_token} = UserToken.build_api_token(user, device_name)
        Repo.insert!(user_token)
        {:ok, {token, user}}

      nil ->
        {:error, :invalid_credentials}
    end
  end

  @doc """
  Gets the user for a valid API token, or `nil`.
  """
  def get_user_by_api_token(token) when is_binary(token) do
    with {:ok, query} <- UserToken.verify_api_token_query(token) do
      case Repo.one(query) do
        %User{} = user ->
          touch_user_seen(user)
          user

        nil ->
          nil
      end
    else
      _ -> nil
    end
  end

  def get_user_by_api_token(_), do: nil

  @doc """
  Revokes an API token (used on logout). Always returns `:ok`.
  """
  def delete_api_token(token) when is_binary(token) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded} ->
        hashed = :crypto.hash(:sha256, decoded)
        Repo.delete_all(from(UserToken, where: [token: ^hashed, context: "api"]))
        :ok

      :error ->
        :ok
    end
  end

  def delete_api_token(_), do: :ok

  @doc """
  Gets the user with the given magic link token.
  """
  def get_user_by_magic_link_token(token) do
    with {:ok, query} <- UserToken.verify_magic_link_token_query(token),
         {user, _token} <- Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  @doc """
  Logs the user in by magic link.

  There are three cases to consider:

  1. The user has already confirmed their email. They are logged in
     and the magic link is expired.

  2. The user has not confirmed their email and no password is set.
     In this case, the user gets confirmed, logged in, and all tokens -
     including session ones - are expired. In theory, no other tokens
     exist but we delete all of them for best security practices.

  3. The user has not confirmed their email but a password is set.
     This cannot happen in the default implementation but may be the
     source of security pitfalls. See the "Mixing magic link and password registration" section of
     `mix help phx.gen.auth`.
  """
  def login_user_by_magic_link(token) do
    {:ok, query} = UserToken.verify_magic_link_token_query(token)

    case Repo.one(query) do
      # Prevent session fixation attacks by disallowing magic links for unconfirmed users with password
      {%User{confirmed_at: nil, hashed_password: hash}, _token} when not is_nil(hash) ->
        raise """
        magic link log in is not allowed for unconfirmed users with a password set!

        This cannot happen with the default implementation, which indicates that you
        might have adapted the code to a different use case. Please make sure to read the
        "Mixing magic link and password registration" section of `mix help phx.gen.auth`.
        """

      {%User{enabled: false}, _token} ->
        {:error, :not_found}

      {%User{confirmed_at: nil} = user, _token} ->
        user
        |> User.confirm_changeset()
        |> update_user_and_delete_all_tokens()

      {user, token} ->
        Repo.delete!(token)
        {:ok, {user, []}}

      nil ->
        {:error, :not_found}
    end
  end

  @doc ~S"""
  Delivers the update email instructions to the given user.

  ## Examples

      iex> deliver_user_update_email_instructions(user, current_email, &url(~p"/users/settings/confirm-email/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_user_update_email_instructions(%User{} = user, current_email, update_email_url_fun)
      when is_function(update_email_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "change:#{current_email}")

    Repo.insert!(user_token)
    UserNotifier.deliver_update_email_instructions(user, update_email_url_fun.(encoded_token))
  end

  @doc """
  Delivers the magic link login instructions to the given user.
  """
  def deliver_login_instructions(%User{} = user, magic_link_url_fun)
      when is_function(magic_link_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "login")
    Repo.insert!(user_token)
    UserNotifier.deliver_login_instructions(user, magic_link_url_fun.(encoded_token))
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_user_session_token(token) do
    Repo.delete_all(from(UserToken, where: [token: ^token, context: "session"]))
    :ok
  end

  def touch_user_seen(%User{} = user) do
    now = DateTime.utc_now(:second)
    stale_before = DateTime.add(now, -5, :minute)

    Repo.update_all(
      from(u in User,
        where: u.id == ^user.id,
        where: is_nil(u.last_seen_at) or u.last_seen_at < ^stale_before
      ),
      set: [last_seen_at: now]
    )

    :ok
  end

  ## Player settings

  @doc """
  Returns the user's player settings, falling back to defaults.
  """
  def get_player_settings(%User{player_settings: %Pageless.Accounts.PlayerSettings{} = settings}),
    do: settings

  def get_player_settings(%User{}), do: %Pageless.Accounts.PlayerSettings{}
  def get_player_settings(_), do: %Pageless.Accounts.PlayerSettings{}

  @doc """
  Updates the user's player settings.
  """
  def update_player_settings(%User{} = user, attrs) do
    Repo.transaction(fn ->
      current_user = User |> where(id: ^user.id) |> lock("FOR UPDATE") |> Repo.one!()

      case current_user |> User.player_settings_changeset(attrs) |> Repo.update() do
        {:ok, updated_user} -> updated_user
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  ## Token helper

  defp update_user_and_delete_all_tokens(changeset) do
    Repo.transact(fn ->
      with {:ok, user} <- Repo.update(changeset) do
        tokens_to_expire = Repo.all_by(UserToken, user_id: user.id)

        Repo.delete_all(from(t in UserToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id)))

        {:ok, {user, tokens_to_expire}}
      end
    end)
  end
end
