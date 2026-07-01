defmodule Pageless.AudibleTest do
  use ExUnit.Case, async: true

  alias Pageless.Audible

  describe "fetch_chapters/3" do
    test "rejects invalid ASINs before making a request" do
      Req.Test.stub(__MODULE__, fn _conn -> flunk("HTTP request made for invalid ASIN") end)

      for asin <- [nil, "", "short", "B017V4IM1!", "B017V4IM1é", "B017V4IM1G0"] do
        assert {:error, :invalid_asin} = Audible.fetch_chapters(asin, "us", request_opts())
      end
    end

    test "rejects unsupported regions before making a request" do
      Req.Test.stub(__MODULE__, fn _conn -> flunk("HTTP request made for invalid region") end)

      for region <- [nil, "", "br", :nz, 1] do
        assert {:error, :invalid_region} =
                 Audible.fetch_chapters("B017V4IM1G", region, request_opts())
      end
    end

    test "normalizes the ASIN and region in the request path and query" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/books/B017V4IM1G/chapters"
        assert conn.query_string == "region=uk"

        Req.Test.json(conn, %{payload() | "region" => "uk"})
      end)

      assert {:ok, lookup} =
               Audible.fetch_chapters("  b017v4im1g ", " UK ", request_opts())

      assert lookup.asin == "B017V4IM1G"
      assert lookup.region == "uk"
    end

    test "parses and normalizes a successful response" do
      stub_json(payload())

      assert {:ok, lookup} = Audible.fetch_chapters("B017V4IM1G", :us, request_opts())

      assert lookup == %{
               asin: "B017V4IM1G",
               region: "us",
               runtime_length_ms: 12_345,
               runtime_length_seconds: 12,
               brand_intro_duration_ms: 1_500,
               brand_outro_duration_ms: 750,
               chapters: [
                 %{title: "Opening", start_offset_ms: 0, start_seconds: 0.0, length_ms: 1_500},
                 %{
                   title: "Chapter 1",
                   start_offset_ms: 1_501,
                   start_seconds: 1.501,
                   length_ms: 10_094
                 },
                 %{
                   title: "Credits",
                   start_offset_ms: 11_595,
                   start_seconds: 11.595,
                   length_ms: 750
                 }
               ]
             }
    end

    test "derives precise chapter seconds from milliseconds instead of startOffsetSec" do
      body =
        payload()
        |> put_in(["chapters", Access.at(1), "startOffsetMs"], 12_345)
        |> put_in(["chapters", Access.at(1), "startOffsetSec"], 12)

      stub_json(body)

      assert {:ok, %{chapters: [_, chapter | _]}} =
               Audible.fetch_chapters("B017V4IM1G", "us", request_opts())

      assert chapter.start_seconds == 12.345
    end

    test "returns not found for a 404 response" do
      stub_status(404)
      assert {:error, :not_found} = Audible.fetch_chapters("B017V4IM1G", "us", request_opts())
    end

    test "returns rate limited for a 429 response without retrying" do
      Req.Test.expect(__MODULE__, 1, fn conn -> Plug.Conn.send_resp(conn, 429, "slow down") end)

      assert {:error, :rate_limited} =
               Audible.fetch_chapters("B017V4IM1G", "us", request_opts())
    end

    test "returns other HTTP statuses" do
      stub_status(503)

      assert {:error, {:http_status, 503}} =
               Audible.fetch_chapters("B017V4IM1G", "us", request_opts())
    end

    test "returns transport errors" do
      Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :timeout) end)

      assert {:error, %Req.TransportError{reason: :timeout}} =
               Audible.fetch_chapters("B017V4IM1G", "us", request_opts())
    end

    test "rejects malformed payloads without raising" do
      malformed = put_in(payload(), ["chapters", Access.at(0), "startOffsetMs"], -1)
      stub_json(malformed)

      assert {:error, :malformed_payload} =
               Audible.fetch_chapters("B017V4IM1G", "us", request_opts())
    end

    test "rejects a non-list chapters value" do
      stub_json(%{payload() | "chapters" => %{}})

      assert {:error, :malformed_payload} =
               Audible.fetch_chapters("B017V4IM1G", "us", request_opts())
    end

    test "treats an empty chapter list as not found" do
      stub_json(%{payload() | "chapters" => []})

      assert {:error, :not_found} =
               Audible.fetch_chapters("B017V4IM1G", "us", request_opts())
    end

    test "rejects empty and oversized chapter titles" do
      for title <- ["  ", String.duplicate("x", 256)] do
        body = put_in(payload(), ["chapters", Access.at(0), "title"], title)
        stub_json(body)

        assert {:error, :malformed_payload} =
                 Audible.fetch_chapters("B017V4IM1G", "us", request_opts())
      end
    end

    test "rejects invalid JSON as a malformed payload" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, "not json")
      end)

      assert {:error, :malformed_payload} =
               Audible.fetch_chapters("B017V4IM1G", "us", request_opts())
    end
  end

  describe "remove_branding/1" do
    test "removes intro and outro timing using Audiobookshelf chapter behavior" do
      lookup = normalized_lookup()

      assert Audible.remove_branding(lookup) == %{
               lookup
               | runtime_length_ms: 10_095,
                 runtime_length_seconds: 10.095,
                 chapters: [
                   %{title: "Opening", start_offset_ms: 0, start_seconds: 0.0, length_ms: 1_500},
                   %{
                     title: "Preface",
                     start_offset_ms: 1_000,
                     start_seconds: 1.0,
                     length_ms: 500
                   },
                   %{
                     title: "Chapter 1",
                     start_offset_ms: 1,
                     start_seconds: 0.001,
                     length_ms: 10_094
                   }
                 ]
             }

      assert normalized_lookup().chapters |> List.last() |> Map.fetch!(:title) == "Credits"
    end

    test "keeps a final chapter longer than the outro and clamps runtime to zero" do
      lookup = %{
        normalized_lookup()
        | runtime_length_ms: 1_000,
          brand_intro_duration_ms: 700,
          brand_outro_duration_ms: 500,
          chapters: [%{title: "Only", start_offset_ms: 0, start_seconds: 0.0, length_ms: 501}]
      }

      assert %{runtime_length_ms: 0, chapters: [chapter]} =
               transformed =
               Audible.remove_branding(lookup)

      assert transformed.runtime_length_seconds == 0.0
      assert chapter.start_offset_ms == 0
    end
  end

  defp request_opts, do: [plug: {Req.Test, __MODULE__}]

  defp stub_json(body) do
    Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, body) end)
  end

  defp stub_status(status) do
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, status, "error") end)
  end

  defp payload do
    %{
      "asin" => "B017V4IM1G",
      "region" => "us",
      "runtimeLengthMs" => 12_345,
      "runtimeLengthSec" => 12,
      "brandIntroDurationMs" => 1_500,
      "brandOutroDurationMs" => 750,
      "chapters" => [
        %{"title" => "Opening", "startOffsetMs" => 0, "startOffsetSec" => 0, "lengthMs" => 1_500},
        %{
          "title" => "Chapter 1",
          "startOffsetMs" => 1_501,
          "startOffsetSec" => 1,
          "lengthMs" => 10_094
        },
        %{
          "title" => "Credits",
          "startOffsetMs" => 11_595,
          "startOffsetSec" => 11,
          "lengthMs" => 750
        }
      ]
    }
  end

  defp normalized_lookup do
    %{
      asin: "B017V4IM1G",
      region: "us",
      runtime_length_ms: 12_345,
      runtime_length_seconds: 12.345,
      brand_intro_duration_ms: 1_500,
      brand_outro_duration_ms: 750,
      chapters: [
        %{title: "Opening", start_offset_ms: 0, start_seconds: 0.0, length_ms: 1_500},
        %{title: "Preface", start_offset_ms: 500, start_seconds: 0.5, length_ms: 500},
        %{title: "Chapter 1", start_offset_ms: 1_501, start_seconds: 1.501, length_ms: 10_094},
        %{title: "Credits", start_offset_ms: 11_595, start_seconds: 11.595, length_ms: 750}
      ]
    }
  end
end
