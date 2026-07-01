defmodule PagelessWeb.RangeFile do
  @moduledoc """
  Serves a file over HTTP honoring a single `Range` request, so media clients
  can seek and resume downloads. Shared by the web audio stream and the mobile
  download endpoint.
  """

  import Plug.Conn

  @doc """
  Sends `path` with `accept-ranges` support, responding with `206 Partial
  Content` for a `Range` request or `200` otherwise.
  """
  def send(conn, path, content_type) do
    %{size: size} = File.stat!(path)

    conn =
      conn
      |> put_resp_header("accept-ranges", "bytes")
      |> put_resp_content_type(content_type)

    case get_req_header(conn, "range") do
      ["bytes=" <> range] ->
        {first, last} = parse_range(range, size)
        length = last - first + 1

        conn
        |> put_resp_header("content-range", "bytes #{first}-#{last}/#{size}")
        |> send_file(206, path, first, length)

      _ ->
        send_file(conn, 200, path)
    end
  end

  defp parse_range(range, size) do
    case String.split(range, "-") do
      [first, ""] ->
        first = String.to_integer(first)
        {first, size - 1}

      [first, last] ->
        first = String.to_integer(first)
        last = min(String.to_integer(last), size - 1)
        {first, last}

      [first] ->
        first = String.to_integer(first)
        {first, size - 1}
    end
  end
end
