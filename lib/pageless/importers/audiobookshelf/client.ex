defmodule Pageless.Importers.Audiobookshelf.Client do
  @moduledoc false

  defstruct [:req]

  def new(url, token) when is_binary(url) and is_binary(token) do
    req =
      Req.new(
        base_url: String.trim_trailing(url, "/"),
        auth: {:bearer, token},
        retry: false
      )

    %__MODULE__{req: req}
  end

  def me(%__MODULE__{} = client), do: get_json(client, "/api/me")
  def libraries(%__MODULE__{} = client), do: get_json(client, "/api/libraries")
  def collections(%__MODULE__{} = client), do: get_json(client, "/api/collections")
  def playlists(%__MODULE__{} = client), do: get_json(client, "/api/playlists")

  def library_items(%__MODULE__{} = client, library_id, page, limit) do
    get_json(client, "/api/libraries/#{library_id}/items", %{
      limit: limit,
      page: page,
      minified: 1
    })
  end

  def item(%__MODULE__{} = client, item_id) do
    get_json(client, "/api/items/#{item_id}", %{expanded: 1, include: "progress"})
  end

  def listening_sessions(%__MODULE__{} = client, page, items_per_page) do
    get_json(client, "/api/me/listening-sessions", %{
      page: page,
      itemsPerPage: items_per_page
    })
  end

  def cover(%__MODULE__{req: req}, item_id) do
    case Req.get(req, url: "/api/items/#{item_id}/cover", params: %{raw: 1}) do
      {:ok, %{status: status, body: body, headers: headers}} when status in 200..299 ->
        {:ok, body, content_type(headers)}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_status, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_json(client, path, params \\ %{}) do
    case Req.get(client.req, url: path, params: params) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {:http_status, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp content_type(headers) do
    case Req.Response.get_header(%Req.Response{headers: headers}, "content-type") do
      [value | _] -> value
      _ -> nil
    end
  end
end
