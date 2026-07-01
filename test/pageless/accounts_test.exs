defmodule Pageless.AccountsTest do
  use Pageless.DataCase

  alias Pageless.Accounts

  import Pageless.AccountsFixtures
  alias Pageless.Accounts.{User, UserToken}

  describe "get_user_by_email/1" do
    test "does not return the user if the email does not exist" do
      refute Accounts.get_user_by_email("unknown@example.com")
    end

    test "returns the user if the email exists" do
      %{id: id} = user = user_fixture()
      assert %User{id: ^id} = Accounts.get_user_by_email(user.email)
    end
  end

  describe "get_user_by_email_and_password/2" do
    test "does not return the user if the email does not exist" do
      refute Accounts.get_user_by_email_and_password("unknown@example.com", "hello world!")
    end

    test "does not return the user if the password is not valid" do
      user = user_fixture() |> set_password()
      refute Accounts.get_user_by_email_and_password(user.email, "invalid")
    end

    test "returns the user if the email and password are valid" do
      %{id: id} = user = user_fixture() |> set_password()

      assert %User{id: ^id} =
               Accounts.get_user_by_email_and_password(user.email, valid_user_password())
    end
  end

  describe "get_user!/1" do
    test "raises if id is invalid" do
      assert_raise Ecto.NoResultsError, fn ->
        Accounts.get_user!(Ecto.UUID.generate())
      end
    end

    test "returns the user with the given id" do
      %{id: id} = user = user_fixture()
      assert %User{id: ^id} = Accounts.get_user!(user.id)
    end
  end

  describe "create_initial_admin/1" do
    test "creates a password-ready enabled admin" do
      email = unique_user_email()

      assert {:ok, user} =
               Accounts.create_initial_admin(%{email: email, password: valid_user_password()})

      assert user.email == email
      assert user.role == "admin"
      assert user.enabled
      assert user.confirmed_at
      assert Accounts.get_user_by_email_and_password(email, valid_user_password())
    end

    test "only works before users exist" do
      user_fixture()

      assert {:error, :already_setup} =
               Accounts.create_initial_admin(%{
                 email: unique_user_email(),
                 password: valid_user_password()
               })
    end
  end

  describe "managed users" do
    setup do
      admin = admin_user_fixture()
      scope = user_scope_fixture(admin)
      %{admin: admin, scope: scope}
    end

    test "admin creates users with permissions", %{scope: scope} do
      email = unique_user_email()

      assert {:ok, user} =
               Accounts.create_managed_user(scope, %{
                 email: email,
                 password: valid_user_password(),
                 permissions: %{can_download: false, can_access_all_libraries: true}
               })

      refute user.permissions.can_download
      assert Accounts.get_user_by_email_and_password(email, valid_user_password())
    end

    test "disabled users cannot authenticate", %{scope: scope} do
      user = user_fixture() |> set_password()

      assert {:ok, user} = Accounts.update_managed_user(scope, user, %{enabled: false})
      refute Accounts.get_user_by_email_and_password(user.email, valid_user_password())
    end

    test "cannot disable the last enabled admin", %{admin: admin, scope: scope} do
      assert {:error, :cannot_disable_self} =
               Accounts.update_managed_user(scope, admin, %{enabled: false})
    end

    test "cannot delete self", %{admin: admin, scope: scope} do
      assert {:error, :cannot_delete_self} = Accounts.delete_managed_user(scope, admin)
    end
  end

  describe "register_user/1" do
    test "requires email to be set" do
      {:error, changeset} = Accounts.register_user(%{})

      assert %{email: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates email when given" do
      {:error, changeset} = Accounts.register_user(%{email: "not valid"})

      assert %{email: ["must have the @ sign and no spaces"]} = errors_on(changeset)
    end

    test "validates maximum values for email for security" do
      too_long = String.duplicate("db", 100)
      {:error, changeset} = Accounts.register_user(%{email: too_long})
      assert "should be at most 160 character(s)" in errors_on(changeset).email
    end

    test "validates email uniqueness" do
      %{email: email} = user_fixture()
      {:error, changeset} = Accounts.register_user(%{email: email})
      assert "has already been taken" in errors_on(changeset).email

      # Now try with the uppercased email too, to check that email case is ignored.
      {:error, changeset} = Accounts.register_user(%{email: String.upcase(email)})
      assert "has already been taken" in errors_on(changeset).email
    end

    test "registers users without password" do
      email = unique_user_email()
      {:ok, user} = Accounts.register_user(valid_user_attributes(email: email))
      assert user.email == email
      assert is_nil(user.hashed_password)
      assert is_nil(user.confirmed_at)
      assert is_nil(user.password)
    end
  end

  describe "sudo_mode?/2" do
    test "validates the authenticated_at time" do
      now = DateTime.utc_now()

      assert Accounts.sudo_mode?(%User{authenticated_at: DateTime.utc_now()})
      assert Accounts.sudo_mode?(%User{authenticated_at: DateTime.add(now, -19, :minute)})
      refute Accounts.sudo_mode?(%User{authenticated_at: DateTime.add(now, -21, :minute)})

      # minute override
      refute Accounts.sudo_mode?(
               %User{authenticated_at: DateTime.add(now, -11, :minute)},
               -10
             )

      # not authenticated
      refute Accounts.sudo_mode?(%User{})
    end
  end

  describe "change_user_email/3" do
    test "returns a user changeset" do
      assert %Ecto.Changeset{} = changeset = Accounts.change_user_email(%User{})
      assert changeset.required == [:email]
    end
  end

  describe "deliver_user_update_email_instructions/3" do
    setup do
      %{user: user_fixture()}
    end

    test "sends token through notification", %{user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_update_email_instructions(user, "current@example.com", url)
        end)

      {:ok, token} = Base.url_decode64(token, padding: false)
      assert user_token = Repo.get_by(UserToken, token: :crypto.hash(:sha256, token))
      assert user_token.user_id == user.id
      assert user_token.sent_to == user.email
      assert user_token.context == "change:current@example.com"
    end
  end

  describe "update_user_email/2" do
    setup do
      user = unconfirmed_user_fixture()
      email = unique_user_email()

      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_update_email_instructions(%{user | email: email}, user.email, url)
        end)

      %{user: user, token: token, email: email}
    end

    test "updates the email with a valid token", %{user: user, token: token, email: email} do
      assert {:ok, %{email: ^email}} = Accounts.update_user_email(user, token)
      changed_user = Repo.get!(User, user.id)
      assert changed_user.email != user.email
      assert changed_user.email == email
      refute Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not update email with invalid token", %{user: user} do
      assert Accounts.update_user_email(user, "oops") ==
               {:error, :transaction_aborted}

      assert Repo.get!(User, user.id).email == user.email
      assert Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not update email if user email changed", %{user: user, token: token} do
      assert Accounts.update_user_email(%{user | email: "current@example.com"}, token) ==
               {:error, :transaction_aborted}

      assert Repo.get!(User, user.id).email == user.email
      assert Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not update email if token expired", %{user: user, token: token} do
      {1, nil} = Repo.update_all(UserToken, set: [inserted_at: ~N[2020-01-01 00:00:00]])

      assert Accounts.update_user_email(user, token) ==
               {:error, :transaction_aborted}

      assert Repo.get!(User, user.id).email == user.email
      assert Repo.get_by(UserToken, user_id: user.id)
    end
  end

  describe "change_user_password/3" do
    test "returns a user changeset" do
      assert %Ecto.Changeset{} = changeset = Accounts.change_user_password(%User{})
      assert changeset.required == [:password]
    end

    test "allows fields to be set" do
      changeset =
        Accounts.change_user_password(
          %User{},
          %{
            "password" => "new valid password"
          },
          hash_password: false
        )

      assert changeset.valid?
      assert get_change(changeset, :password) == "new valid password"
      assert is_nil(get_change(changeset, :hashed_password))
    end
  end

  describe "update_user_password/2" do
    setup do
      %{user: user_fixture()}
    end

    test "validates password", %{user: user} do
      {:error, changeset} =
        Accounts.update_user_password(user, %{
          password: "not valid",
          password_confirmation: "another"
        })

      assert %{
               password: ["should be at least 12 character(s)"],
               password_confirmation: ["does not match password"]
             } = errors_on(changeset)
    end

    test "validates maximum values for password for security", %{user: user} do
      too_long = String.duplicate("db", 100)

      {:error, changeset} =
        Accounts.update_user_password(user, %{password: too_long})

      assert "should be at most 72 character(s)" in errors_on(changeset).password
    end

    test "updates the password", %{user: user} do
      {:ok, {user, expired_tokens}} =
        Accounts.update_user_password(user, %{
          password: "new valid password"
        })

      assert expired_tokens == []
      assert is_nil(user.password)
      assert Accounts.get_user_by_email_and_password(user.email, "new valid password")
    end

    test "deletes all tokens for the given user", %{user: user} do
      _ = Accounts.generate_user_session_token(user)

      {:ok, {_, _}} =
        Accounts.update_user_password(user, %{
          password: "new valid password"
        })

      refute Repo.get_by(UserToken, user_id: user.id)
    end
  end

  describe "generate_user_session_token/1" do
    setup do
      %{user: user_fixture()}
    end

    test "generates a token", %{user: user} do
      token = Accounts.generate_user_session_token(user)
      assert user_token = Repo.get_by(UserToken, token: token)
      assert user_token.context == "session"
      assert user_token.authenticated_at != nil

      # Creating the same token for another user should fail
      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%UserToken{
          token: user_token.token,
          user_id: user_fixture().id,
          context: "session"
        })
      end
    end

    test "duplicates the authenticated_at of given user in new token", %{user: user} do
      user = %{user | authenticated_at: DateTime.add(DateTime.utc_now(:second), -3600)}
      token = Accounts.generate_user_session_token(user)
      assert user_token = Repo.get_by(UserToken, token: token)
      assert user_token.authenticated_at == user.authenticated_at
      assert DateTime.compare(user_token.inserted_at, user.authenticated_at) == :gt
    end
  end

  describe "get_user_by_session_token/1" do
    setup do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)
      %{user: user, token: token}
    end

    test "returns user by token", %{user: user, token: token} do
      assert {session_user, token_inserted_at} = Accounts.get_user_by_session_token(token)
      assert session_user.id == user.id
      assert session_user.authenticated_at != nil
      assert token_inserted_at != nil
    end

    test "does not return user for invalid token" do
      refute Accounts.get_user_by_session_token("oops")
    end

    test "does not return user for expired token", %{token: token} do
      dt = ~N[2020-01-01 00:00:00]
      {1, nil} = Repo.update_all(UserToken, set: [inserted_at: dt, authenticated_at: dt])
      refute Accounts.get_user_by_session_token(token)
    end
  end

  describe "get_user_by_magic_link_token/1" do
    setup do
      user = user_fixture()
      {encoded_token, _hashed_token} = generate_user_magic_link_token(user)
      %{user: user, token: encoded_token}
    end

    test "returns user by token", %{user: user, token: token} do
      assert session_user = Accounts.get_user_by_magic_link_token(token)
      assert session_user.id == user.id
    end

    test "does not return user for invalid token" do
      refute Accounts.get_user_by_magic_link_token("oops")
    end

    test "does not return user for expired token", %{token: token} do
      {1, nil} = Repo.update_all(UserToken, set: [inserted_at: ~N[2020-01-01 00:00:00]])
      refute Accounts.get_user_by_magic_link_token(token)
    end
  end

  describe "login_user_by_magic_link/1" do
    test "confirms user and expires tokens" do
      user = unconfirmed_user_fixture()
      refute user.confirmed_at
      {encoded_token, hashed_token} = generate_user_magic_link_token(user)

      assert {:ok, {user, [%{token: ^hashed_token}]}} =
               Accounts.login_user_by_magic_link(encoded_token)

      assert user.confirmed_at
    end

    test "returns user and (deleted) token for confirmed user" do
      user = user_fixture()
      assert user.confirmed_at
      {encoded_token, _hashed_token} = generate_user_magic_link_token(user)
      assert {:ok, {^user, []}} = Accounts.login_user_by_magic_link(encoded_token)
      # one time use only
      assert {:error, :not_found} = Accounts.login_user_by_magic_link(encoded_token)
    end

    test "raises when unconfirmed user has password set" do
      user = unconfirmed_user_fixture()
      {1, nil} = Repo.update_all(User, set: [hashed_password: "hashed"])
      {encoded_token, _hashed_token} = generate_user_magic_link_token(user)

      assert_raise RuntimeError, ~r/magic link log in is not allowed/, fn ->
        Accounts.login_user_by_magic_link(encoded_token)
      end
    end
  end

  describe "delete_user_session_token/1" do
    test "deletes the token" do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)
      assert Accounts.delete_user_session_token(token) == :ok
      refute Accounts.get_user_by_session_token(token)
    end
  end

  describe "deliver_login_instructions/2" do
    setup do
      %{user: unconfirmed_user_fixture()}
    end

    test "sends token through notification", %{user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_login_instructions(user, url)
        end)

      {:ok, token} = Base.url_decode64(token, padding: false)
      assert user_token = Repo.get_by(UserToken, token: :crypto.hash(:sha256, token))
      assert user_token.user_id == user.id
      assert user_token.sent_to == user.email
      assert user_token.context == "login"
    end
  end

  describe "inspect/2 for the User module" do
    test "does not include password" do
      refute inspect(%User{password: "123456"}) =~ "password: \"123456\""
    end
  end

  describe "player settings" do
    test "get_player_settings/1 returns defaults for a fresh user" do
      user = user_fixture()
      settings = Accounts.get_player_settings(user)

      assert settings.use_chapter_track == true
      assert settings.jump_forward == 30
      assert settings.jump_backward == 15
      assert settings.rate_increment == 0.1
      assert settings.playback_rate == 1.0
      assert settings.cover_size == 180
      assert settings.ignore_prefixes_when_sorting == false
      assert settings.date_format == "dd/MM/yyyy"
      assert settings.time_format == "HH:mm"
    end

    test "update_player_settings/2 persists the playback rate" do
      user = user_fixture()

      assert {:ok, updated} = Accounts.update_player_settings(user, %{"playback_rate" => "1.75"})
      assert Accounts.get_player_settings(updated).playback_rate == 1.75
    end

    test "update_player_settings/2 rejects an out-of-range playback rate" do
      user = user_fixture()

      assert {:error, changeset} =
               Accounts.update_player_settings(user, %{"playback_rate" => "5.0"})

      assert %{player_settings: %{playback_rate: [_]}} = errors_on(changeset)
    end

    test "update_player_settings/2 persists the default cover size" do
      user = user_fixture()

      assert {:ok, updated} = Accounts.update_player_settings(user, %{"cover_size" => "320"})
      assert Accounts.get_player_settings(updated).cover_size == 320
    end

    test "update_player_settings/2 persists the title prefix preference" do
      user = user_fixture()

      assert {:ok, updated} =
               Accounts.update_player_settings(user, %{"ignore_prefixes_when_sorting" => "true"})

      assert Accounts.get_player_settings(updated).ignore_prefixes_when_sorting

      reloaded = Accounts.get_user_by_email(user.email)
      assert Accounts.get_player_settings(reloaded).ignore_prefixes_when_sorting
    end

    test "update_player_settings/2 validates and persists date and time formats" do
      user = user_fixture()

      assert {:ok, updated} =
               Accounts.update_player_settings(user, %{
                 "date_format" => "MMMM do, yyyy",
                 "time_format" => "h:mma"
               })

      settings = Accounts.get_player_settings(updated)
      assert settings.date_format == "MMMM do, yyyy"
      assert settings.time_format == "h:mma"

      assert {:error, changeset} =
               Accounts.update_player_settings(updated, %{"date_format" => "arbitrary"})

      assert %{player_settings: %{date_format: ["is invalid"]}} = errors_on(changeset)
    end

    test "update_player_settings/2 merges changes from stale user structs" do
      user = user_fixture()

      assert {:ok, _updated} =
               Accounts.update_player_settings(user, %{"ignore_prefixes_when_sorting" => true})

      assert {:ok, updated} = Accounts.update_player_settings(user, %{"playback_rate" => "1.5"})
      settings = Accounts.get_player_settings(updated)
      assert settings.ignore_prefixes_when_sorting
      assert settings.playback_rate == 1.5
    end

    test "update_player_settings/2 rejects out-of-range cover sizes" do
      user = user_fixture()

      assert {:error, changeset} = Accounts.update_player_settings(user, %{"cover_size" => "400"})
      assert %{player_settings: %{cover_size: [_]}} = errors_on(changeset)
    end

    test "update_player_settings/2 persists changes" do
      user = user_fixture()

      assert {:ok, updated} =
               Accounts.update_player_settings(user, %{
                 "use_chapter_track" => "false",
                 "jump_forward" => "10",
                 "jump_backward" => "5",
                 "rate_increment" => "0.25"
               })

      settings = Accounts.get_player_settings(updated)
      assert settings.use_chapter_track == false
      assert settings.jump_forward == 10
      assert settings.jump_backward == 5
      assert settings.rate_increment == 0.25

      # Reloaded from the database
      reloaded = Accounts.get_user_by_email(user.email)
      assert Accounts.get_player_settings(reloaded).jump_forward == 10
    end

    test "update_player_settings/2 rejects invalid jump amounts" do
      user = user_fixture()
      assert {:error, changeset} = Accounts.update_player_settings(user, %{"jump_forward" => "7"})
      assert %{player_settings: %{jump_forward: ["is invalid"]}} = errors_on(changeset)
    end
  end

  describe "API tokens" do
    setup do
      %{user: set_password(user_fixture())}
    end

    test "create_api_token/3 issues a working token", %{user: user} do
      assert {:ok, {token, returned}} =
               Accounts.create_api_token(user.email, valid_user_password(), "Pixel")

      assert returned.id == user.id
      assert %User{id: id} = Accounts.get_user_by_api_token(token)
      assert id == user.id
    end

    test "create_api_token/3 rejects bad credentials", %{user: user} do
      assert {:error, :invalid_credentials} =
               Accounts.create_api_token(user.email, "nope", "Pixel")
    end

    test "get_user_by_api_token/1 rejects garbage and session tokens", %{user: user} do
      assert Accounts.get_user_by_api_token("not-a-token") == nil
      session = Accounts.generate_user_session_token(user)
      assert Accounts.get_user_by_api_token(session) == nil
    end

    test "delete_api_token/1 revokes it", %{user: user} do
      {:ok, {token, _}} = Accounts.create_api_token(user.email, valid_user_password(), "Pixel")
      assert :ok = Accounts.delete_api_token(token)
      assert Accounts.get_user_by_api_token(token) == nil
    end

    test "api token is stored hashed, not in the clear", %{user: user} do
      {:ok, {token, _}} = Accounts.create_api_token(user.email, valid_user_password(), "Pixel")
      decoded = Base.url_decode64!(token, padding: false)
      hashed = :crypto.hash(:sha256, decoded)
      assert %UserToken{context: "api"} = Repo.get_by(UserToken, token: hashed)
      refute Repo.get_by(UserToken, token: decoded)
    end
  end
end
