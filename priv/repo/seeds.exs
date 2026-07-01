# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# This seeds a default admin account in development so you can log in and
# scan a library immediately. Override the credentials with the
# PAGELESS_ADMIN_EMAIL / PAGELESS_ADMIN_PASSWORD environment variables.

alias Pageless.Accounts
alias Pageless.Repo

email = System.get_env("PAGELESS_ADMIN_EMAIL", "admin@example.com")
password = System.get_env("PAGELESS_ADMIN_PASSWORD", "changemechangeme")

case Accounts.get_user_by_email(email) do
  nil ->
    {:ok, user} = Accounts.register_user(%{email: email})

    user
    |> Ecto.Changeset.change(
      role: "admin",
      confirmed_at: DateTime.utc_now(:second),
      hashed_password: Bcrypt.hash_pwd_salt(password)
    )
    |> Repo.update!()

    IO.puts("Created admin user #{email} (password: #{password})")

  _user ->
    IO.puts("Admin user #{email} already exists; skipping.")
end
