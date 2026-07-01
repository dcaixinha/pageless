defmodule Pageless.Repo do
  use Ecto.Repo,
    otp_app: :pageless,
    adapter: Ecto.Adapters.Postgres
end
