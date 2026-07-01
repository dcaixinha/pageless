defmodule Pageless.Audible do
  @moduledoc """
  Looks up and normalizes Audible chapter metadata from Audnexus.
  """

  @endpoint "https://api.audnex.us"
  @regions ~w(us ca uk au fr de jp it in es)
  @timeout 10_000

  @callback fetch_chapters(term(), term()) :: {:ok, map()} | {:error, term()}

  @spec fetch_chapters(term(), term(), keyword()) :: {:ok, map()} | {:error, term()}
  def fetch_chapters(asin, region, opts \\ []) do
    with {:ok, asin} <- normalize_asin(asin),
         {:ok, region} <- normalize_region(region) do
      request_chapters(asin, region, opts)
    end
  end

  @spec remove_branding(map()) :: map()
  def remove_branding(
        %{
          brand_intro_duration_ms: intro,
          brand_outro_duration_ms: outro,
          runtime_length_ms: runtime,
          chapters: chapters
        } = lookup
      ) do
    chapters =
      chapters
      |> maybe_remove_outro(outro)
      |> Enum.with_index()
      |> Enum.map(fn {chapter, index} ->
        start_offset_ms =
          if chapter.start_offset_ms < intro,
            do: index * 1_000,
            else: chapter.start_offset_ms - intro

        %{chapter | start_offset_ms: start_offset_ms, start_seconds: start_offset_ms / 1_000}
      end)

    runtime_length_ms = max(runtime - intro - outro, 0)

    %{
      lookup
      | chapters: chapters,
        runtime_length_ms: runtime_length_ms,
        runtime_length_seconds: runtime_length_ms / 1_000
    }
  end

  defp normalize_asin(asin) when is_binary(asin) do
    asin = asin |> String.trim() |> String.upcase()

    if byte_size(asin) == 10 and asin =~ ~r/\A[A-Z0-9]{10}\z/ do
      {:ok, asin}
    else
      {:error, :invalid_asin}
    end
  end

  defp normalize_asin(_asin), do: {:error, :invalid_asin}

  defp normalize_region(region) when is_atom(region),
    do: region |> Atom.to_string() |> normalize_region()

  defp normalize_region(region) when is_binary(region) do
    region = region |> String.trim() |> String.downcase()

    if region in @regions, do: {:ok, region}, else: {:error, :invalid_region}
  end

  defp normalize_region(_region), do: {:error, :invalid_region}

  defp request_chapters(asin, region, opts) do
    request_opts =
      opts
      |> Keyword.merge(
        url: "#{@endpoint}/books/#{asin}/chapters",
        params: [region: region],
        retry: false,
        receive_timeout: @timeout,
        pool_timeout: @timeout,
        connect_options: [timeout: @timeout]
      )

    case Req.get(request_opts) do
      {:ok, %{status: 200, body: body}} -> normalize_lookup(body, asin, region)
      {:ok, %{status: 404}} -> {:error, :not_found}
      {:ok, %{status: 429}} -> {:error, :rate_limited}
      {:ok, %{status: status}} -> {:error, {:http_status, status}}
      {:error, %Jason.DecodeError{}} -> {:error, :malformed_payload}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_lookup(
         %{
           "asin" => response_asin,
           "region" => response_region,
           "runtimeLengthMs" => runtime_length_ms,
           "runtimeLengthSec" => runtime_length_seconds,
           "brandIntroDurationMs" => intro,
           "brandOutroDurationMs" => outro,
           "chapters" => chapters
         },
         asin,
         region
       )
       when is_binary(response_asin) and is_binary(response_region) and
              is_number(runtime_length_ms) and runtime_length_ms >= 0 and is_number(intro) and
              intro >= 0 and is_number(outro) and outro >= 0 and
              is_number(runtime_length_seconds) and runtime_length_seconds >= 0 and
              is_list(chapters) do
    with true <- String.upcase(response_asin) == asin,
         true <- String.downcase(response_region) == region,
         {:ok, chapters} <- normalize_chapters(chapters) do
      {:ok,
       %{
         asin: asin,
         region: region,
         runtime_length_ms: runtime_length_ms,
         runtime_length_seconds: runtime_length_seconds,
         brand_intro_duration_ms: intro,
         brand_outro_duration_ms: outro,
         chapters: chapters
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :malformed_payload}
    end
  end

  defp normalize_lookup(_body, _asin, _region), do: {:error, :malformed_payload}

  defp normalize_chapters([]), do: {:error, :not_found}

  defp normalize_chapters(chapters) do
    Enum.reduce_while(chapters, {:ok, []}, fn chapter, {:ok, normalized} ->
      case normalize_chapter(chapter) do
        {:ok, chapter} -> {:cont, {:ok, [chapter | normalized]}}
        :error -> {:halt, {:error, :malformed_payload}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp normalize_chapter(%{
         "title" => title,
         "startOffsetMs" => start_offset_ms,
         "lengthMs" => length_ms
       })
       when is_binary(title) and is_number(start_offset_ms) and start_offset_ms >= 0 and
              is_number(length_ms) and length_ms >= 0 do
    title = String.trim(title)

    if title != "" and String.length(title) <= 255 do
      {:ok,
       %{
         title: title,
         start_offset_ms: start_offset_ms,
         start_seconds: start_offset_ms / 1_000,
         length_ms: length_ms
       }}
    else
      :error
    end
  end

  defp normalize_chapter(_chapter), do: :error

  defp maybe_remove_outro([], _outro), do: []

  defp maybe_remove_outro(chapters, outro) do
    if List.last(chapters).length_ms <= outro, do: List.delete_at(chapters, -1), else: chapters
  end
end
