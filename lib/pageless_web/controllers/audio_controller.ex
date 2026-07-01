defmodule PagelessWeb.AudioController do
  @moduledoc """
  Streams a book's audio file with HTTP Range support so the browser's
  `<audio>` element can seek and resume.

  Access is authorized either by the authenticated session (via the browser
  pipeline) or a short-lived signed token, which lets the `<audio>` `src`
  attribute work without cookies in some contexts.
  """
  use PagelessWeb, :controller

  alias Pageless.Accounts
  alias Pageless.Library

  @token_salt "audio stream"
  @token_max_age 60 * 60 * 6

  @doc """
  Signs a token granting access to a book's audio for the given user.
  """
  def sign_token(conn_or_endpoint, user_id, book_id) do
    Phoenix.Token.sign(conn_or_endpoint, @token_salt, %{user_id: user_id, book_id: book_id})
  end

  def stream(conn, %{"id" => id} = params) do
    with {:ok, scope} <- authorize(conn, id, params["token"]),
         %{audio_files: [audio | _]} <- Library.get_book(scope, id),
         true <- File.exists?(audio.path) do
      PagelessWeb.RangeFile.send(conn, audio.path, audio.mime_type || "audio/mp4")
    else
      _ -> send_resp(conn, 404, "")
    end
  end

  defp authorize(conn, book_id, token) do
    cond do
      conn.assigns[:current_scope] && conn.assigns.current_scope.user ->
        {:ok, conn.assigns.current_scope}

      is_binary(token) ->
        case Phoenix.Token.verify(PagelessWeb.Endpoint, @token_salt, token,
               max_age: @token_max_age
             ) do
          {:ok, %{user_id: user_id, book_id: signed_book_id}} ->
            if to_string(signed_book_id) == to_string(book_id) do
              user = Accounts.get_user!(user_id)

              if Accounts.User.enabled?(user) do
                {:ok, Accounts.Scope.for_user(user)}
              else
                :error
              end
            else
              :error
            end

          _ ->
            :error
        end

      true ->
        :error
    end
  end
end
