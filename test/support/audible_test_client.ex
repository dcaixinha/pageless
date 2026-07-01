defmodule Pageless.AudibleTestClient do
  @behaviour Pageless.Audible

  @impl true
  def fetch_chapters("B017V4IM1G", region) do
    {:ok,
     %{
       asin: "B017V4IM1G",
       region: String.downcase(region),
       runtime_length_ms: 900_000,
       runtime_length_seconds: 900.0,
       brand_intro_duration_ms: 4_000,
       brand_outro_duration_ms: 5_000,
       chapters: [
         %{title: "Opening Credits", start_offset_ms: 0, start_seconds: 0.0, length_ms: 10_000},
         %{
           title: "Audible Chapter One",
           start_offset_ms: 10_500,
           start_seconds: 10.5,
           length_ms: 589_500
         },
         %{
           title: "Audible Chapter Two",
           start_offset_ms: 600_000,
           start_seconds: 600.0,
           length_ms: 295_000
         },
         %{title: "End Credits", start_offset_ms: 895_000, start_seconds: 895.0, length_ms: 5_000}
       ]
     }}
  end

  def fetch_chapters("0000000000", _region), do: {:error, :not_found}
  def fetch_chapters(asin, _region) when byte_size(asin) != 10, do: {:error, :invalid_asin}
  def fetch_chapters(_asin, _region), do: {:error, :unavailable}
end
