defmodule Pageless.Library.RemoteCover do
  @moduledoc false

  import Bitwise

  @max_bytes 15_000_000
  @max_redirects 3
  @timeout 10_000
  @total_timeout 15_000
  @redirect_statuses [301, 302, 303, 307, 308]

  def fetch(url, opts \\ []) when is_binary(url) do
    resolver = Keyword.get(opts, :resolver, &resolve_host/1)
    max_bytes = Keyword.get(opts, :max_bytes, @max_bytes)
    max_redirects = Keyword.get(opts, :max_redirects, @max_redirects)
    total_timeout = Keyword.get(opts, :total_timeout, @total_timeout)
    request_options = Keyword.get(opts, :request_options, [])

    if total_timeout <= 0 do
      {:error, :timeout}
    else
      task =
        Task.Supervisor.async_nolink(Pageless.HTTPTaskSupervisor, fn ->
          deadline = System.monotonic_time(:millisecond) + total_timeout

          with {:ok, target} <- validate_url(url, resolver) do
            request(target, resolver, max_bytes, max_redirects, request_options, deadline)
          end
        end)

      case Task.yield(task, total_timeout) || Task.shutdown(task) do
        {:ok, result} -> result
        {:exit, reason} -> {:error, reason}
        nil -> {:error, :timeout}
      end
    end
  end

  defp request(target, resolver, max_bytes, redirects_left, request_options, deadline) do
    timeout = min(@timeout, remaining_timeout(deadline))

    if timeout <= 0 do
      {:error, :timeout}
    else
      run_request(
        target,
        resolver,
        max_bytes,
        redirects_left,
        request_options,
        deadline,
        timeout
      )
    end
  end

  defp run_request(
         target,
         resolver,
         max_bytes,
         redirects_left,
         request_options,
         deadline,
         timeout
       ) do
    options =
      [
        url: target |> pinned_uri() |> URI.to_string(),
        headers: [{"accept", "image/png,image/jpeg,image/webp"}],
        redirect: false,
        retry: false,
        raw: true,
        receive_timeout: timeout,
        pool_timeout: timeout,
        connect_options: [timeout: timeout, hostname: target.uri.host],
        into: limited_body(max_bytes, deadline)
      ]
      |> Keyword.merge(request_options)

    case Req.get(options) do
      {:ok, %{status: status} = response} when status in 200..299 ->
        normalize_image(response, max_bytes)

      {:ok, %{status: status} = response} when status in @redirect_statuses ->
        follow_redirect(
          response,
          target,
          resolver,
          max_bytes,
          redirects_left,
          request_options,
          deadline
        )

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp follow_redirect(
         _response,
         _target,
         _resolver,
         _max_bytes,
         0,
         _request_options,
         _deadline
       ),
       do: {:error, :too_many_redirects}

  defp follow_redirect(
         response,
         target,
         resolver,
         max_bytes,
         redirects_left,
         request_options,
         deadline
       ) do
    with [location | _] <- Req.Response.get_header(response, "location"),
         {:ok, redirect_uri} <- merge_uri(target.uri, location),
         {:ok, redirect_target} <- validate_url(redirect_uri, resolver) do
      request(
        redirect_target,
        resolver,
        max_bytes,
        redirects_left - 1,
        request_options,
        deadline
      )
    else
      [] -> {:error, :invalid_redirect}
      {:error, reason} -> {:error, reason}
    end
  end

  defp merge_uri(base, location) do
    case URI.new(location) do
      {:ok, location_uri} -> {:ok, URI.merge(base, location_uri)}
      {:error, _part} -> {:error, :invalid_redirect}
    end
  rescue
    ArgumentError -> {:error, :invalid_redirect}
  end

  defp validate_url(%URI{} = uri, resolver), do: validate_uri(uri, resolver)

  defp validate_url(url, resolver) do
    case URI.new(String.trim(url)) do
      {:ok, uri} -> validate_uri(uri, resolver)
      {:error, _part} -> {:error, :invalid_url}
    end
  end

  defp validate_uri(%URI{scheme: scheme, host: host, userinfo: nil} = uri, resolver)
       when scheme in ["http", "https"] and is_binary(host) and host != "" do
    host = host |> String.downcase() |> String.trim_trailing(".")

    with false <- local_hostname?(host),
         {:ok, addresses} <- resolve_addresses(host, resolver),
         true <- addresses != [] and Enum.all?(addresses, &public_ip?/1) do
      {:ok, %{uri: %{uri | host: host}, address: List.first(addresses)}}
    else
      true -> {:error, :private_address}
      false -> {:error, :private_address}
      {:error, _reason} -> {:error, :unresolvable_host}
    end
  end

  defp validate_uri(_uri, _resolver), do: {:error, :invalid_url}

  defp local_hostname?(host) do
    host == "localhost" or String.ends_with?(host, ".localhost") or
      String.ends_with?(host, ".local")
  end

  defp resolve_addresses(host, resolver) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} -> {:ok, [address]}
      {:error, :einval} -> resolver.(host)
    end
  end

  defp resolve_host(host) do
    char_host = String.to_charlist(host)

    case :inet.parse_address(char_host) do
      {:ok, address} ->
        {:ok, [address]}

      {:error, :einval} ->
        addresses = resolved_addresses(char_host, :inet) ++ resolved_addresses(char_host, :inet6)
        if addresses == [], do: {:error, :nxdomain}, else: {:ok, Enum.uniq(addresses)}
    end
  end

  defp pinned_uri(%{uri: uri, address: address}) do
    %{uri | host: address |> :inet.ntoa() |> to_string()}
  end

  defp resolved_addresses(host, family) do
    case :inet.getaddrs(host, family) do
      {:ok, addresses} -> addresses
      {:error, _reason} -> []
    end
  end

  defp public_ip?({a, b, c, _d}) do
    cond do
      a in [0, 10, 127] -> false
      a >= 224 -> false
      a == 100 and b in 64..127 -> false
      a == 169 and b == 254 -> false
      a == 172 and b in 16..31 -> false
      a == 192 and b == 168 -> false
      a == 192 and b == 0 and c in [0, 2] -> false
      a == 192 and b == 88 and c == 99 -> false
      a == 198 and b in [18, 19] -> false
      a == 198 and b == 51 and c == 100 -> false
      a == 203 and b == 0 and c == 113 -> false
      true -> true
    end
  end

  defp public_ip?({0, 0, 0, 0, 0, 0, 0, 0}), do: false
  defp public_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: false

  defp public_ip?({0, 0, 0, 0, 0, 0xFFFF, high, low}) do
    public_ip?({high >>> 8, high &&& 0xFF, low >>> 8, low &&& 0xFF})
  end

  defp public_ip?({first, second, _c, _d, _e, _f, _g, _h}) do
    cond do
      (first &&& 0xE000) != 0x2000 -> false
      first == 0x2001 and second == 0x0DB8 -> false
      first == 0x2002 -> false
      true -> true
    end
  end

  defp normalize_image(%{body: {:too_large, _size}}, _max_bytes), do: {:error, :too_large}
  defp normalize_image(%{body: :timeout}, _max_bytes), do: {:error, :timeout}

  defp normalize_image(%{body: body, headers: headers}, max_bytes) when is_binary(body) do
    cond do
      content_length_exceeds?(headers, max_bytes) -> {:error, :too_large}
      byte_size(body) > max_bytes -> {:error, :too_large}
      not image_content_type?(headers) -> {:error, :not_an_image}
      extension = image_extension(body) -> {:ok, %{body: body, extension: extension}}
      true -> {:error, :not_an_image}
    end
  end

  defp normalize_image(_response, _max_bytes), do: {:error, :not_an_image}

  defp limited_body(max_bytes, deadline) do
    fn {:data, data}, {request, response} ->
      body = response.body || <<>>
      size = byte_size(body) + byte_size(data)

      cond do
        remaining_timeout(deadline) <= 0 ->
          {:halt, {request, %{response | body: :timeout}}}

        size > max_bytes ->
          {:halt, {request, %{response | body: {:too_large, size}}}}

        true ->
          {:cont, {request, %{response | body: body <> data}}}
      end
    end
  end

  defp remaining_timeout(deadline), do: deadline - System.monotonic_time(:millisecond)

  defp content_length_exceeds?(headers, max_bytes) do
    headers
    |> header_values("content-length")
    |> Enum.any?(fn value ->
      case Integer.parse(value) do
        {length, ""} -> length > max_bytes
        _ -> false
      end
    end)
  end

  defp image_content_type?(headers) do
    case header_values(headers, "content-type") do
      [] -> true
      values -> Enum.any?(values, &String.starts_with?(String.downcase(&1), "image/"))
    end
  end

  defp header_values(headers, name) do
    case headers[name] || headers[String.capitalize(name)] do
      values when is_list(values) -> values
      value when is_binary(value) -> [value]
      _ -> []
    end
  end

  defp image_extension(
         <<0x89, "PNG\r\n", 0x1A, "\n", 13::unsigned-big-32, "IHDR", width::unsigned-big-32,
           height::unsigned-big-32, _rest::binary>> = body
       )
       when width > 0 and height > 0 do
    if byte_size(body) >= 45 and
         :binary.part(body, byte_size(body) - 12, 8) == <<0::unsigned-big-32, "IEND">> do
      "png"
    end
  end

  defp image_extension(<<0xFF, 0xD8, 0xFF, _rest::binary>> = body) when byte_size(body) >= 6 do
    if :binary.part(body, byte_size(body) - 2, 2) == <<0xFF, 0xD9>>, do: "jpg"
  end

  defp image_extension(
         <<"RIFF", declared_size::unsigned-little-32, "WEBP", chunk::binary-size(4),
           _rest::binary>> = body
       )
       when chunk in ["VP8 ", "VP8L", "VP8X"] and declared_size == byte_size(body) - 8,
       do: "webp"

  defp image_extension(_body), do: nil
end
