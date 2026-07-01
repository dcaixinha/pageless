defmodule Pageless.Library.RemoteCoverTest do
  use ExUnit.Case, async: true

  alias Pageless.Library.RemoteCover

  describe "fetch/2" do
    test "returns a validated image and derives its extension from its bytes" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("image/png")
        |> Plug.Conn.send_resp(200, png())
      end)

      assert {:ok, %{body: body, extension: "png"}} = fetch("https://covers.example/book")
      assert body == png()
    end

    test "accepts an image without a content-type header when its signature is valid" do
      Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 200, jpeg()) end)

      assert {:ok, %{extension: "jpg"}} = fetch("https://covers.example/book.jpg")
    end

    test "rejects non-http schemes and URLs containing credentials" do
      assert {:error, :invalid_url} = fetch("file:///etc/passwd")
      assert {:error, :invalid_url} = fetch("https://user:pass@covers.example/book")
    end

    test "rejects private literal addresses before making a request" do
      Req.Test.stub(__MODULE__, fn _conn -> flunk("request reached private address") end)

      for url <- [
            "http://127.0.0.1/cover.jpg",
            "http://10.0.0.1/cover.jpg",
            "http://169.254.169.254/latest/meta-data",
            "http://[::1]/cover.jpg",
            "http://[fc00::1]/cover.jpg",
            "http://[::ffff:0:127.0.0.1]/cover.jpg",
            "http://[64:ff9b::127.0.0.1]/cover.jpg"
          ] do
        assert {:error, :private_address} = fetch(url)
      end
    end

    test "rejects hostnames resolving to private or mixed public/private addresses" do
      private = fn _host -> {:ok, [{192, 168, 1, 2}]} end
      mixed = fn _host -> {:ok, [{93, 184, 216, 34}, {127, 0, 0, 1}]} end

      assert {:error, :private_address} = fetch("https://covers.example/book", resolver: private)
      assert {:error, :private_address} = fetch("https://covers.example/book", resolver: mixed)
    end

    test "validates redirect targets and blocks redirects to private addresses" do
      Req.Test.expect(__MODULE__, 1, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "http://127.0.0.1/internal")
        |> Plug.Conn.send_resp(302, "")
      end)

      assert {:error, :private_address} = fetch("https://covers.example/book")
    end

    test "follows a bounded public redirect" do
      Req.Test.expect(__MODULE__, 2, fn conn ->
        case conn.request_path do
          "/old" ->
            conn
            |> Plug.Conn.put_resp_header("location", "/new")
            |> Plug.Conn.send_resp(302, "")

          "/new" ->
            conn
            |> Plug.Conn.put_resp_content_type("image/webp")
            |> Plug.Conn.send_resp(200, webp())
        end
      end)

      assert {:ok, %{extension: "webp"}} = fetch("https://covers.example/old")
    end

    test "rejects oversized response bodies and content lengths" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-length", "100")
        |> Plug.Conn.send_resp(200, png())
      end)

      assert {:error, :too_large} = fetch("https://covers.example/book", max_bytes: 10)
    end

    test "rejects spoofed and unsupported image responses" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("image/png")
        |> Plug.Conn.send_resp(200, "not really an image")
      end)

      assert {:error, :not_an_image} = fetch("https://covers.example/book")
    end

    test "rejects truncated image signatures" do
      for body <- [
            <<0x89, "PNG\r\n", 0x1A, "\n">>,
            <<0xFF, 0xD8, 0xFF>>,
            <<"RIFF", 4::little-32, "WEBP">>
          ] do
        Req.Test.stub(__MODULE__, fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("image/png")
          |> Plug.Conn.send_resp(200, body)
        end)

        assert {:error, :not_an_image} = fetch("https://covers.example/book")
      end
    end

    test "enforces an end-to-end request deadline" do
      Req.Test.stub(__MODULE__, fn _conn -> flunk("request started after deadline") end)

      assert {:error, :timeout} = fetch("https://covers.example/book", total_timeout: 0)
    end

    test "stops an in-flight request at the total deadline" do
      Req.Test.stub(__MODULE__, fn conn ->
        Process.sleep(100)
        Plug.Conn.send_resp(conn, 200, png())
      end)

      assert {:error, :timeout} = fetch("https://covers.example/book", total_timeout: 10)
    end

    test "returns bounded transport and HTTP errors" do
      Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :timeout) end)

      assert {:error, %Req.TransportError{reason: :timeout}} =
               fetch("https://covers.example/book")

      Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 503, "unavailable") end)
      assert {:error, {:http_status, 503}} = fetch("https://covers.example/book")
    end
  end

  defp fetch(url, extra_opts \\ []) do
    opts =
      [
        resolver: &public_resolver/1,
        request_options: [plug: {Req.Test, __MODULE__}]
      ]
      |> Keyword.merge(extra_opts)

    RemoteCover.fetch(url, opts)
  end

  defp public_resolver(_host), do: {:ok, [{93, 184, 216, 34}]}

  defp png do
    <<0x89, "PNG\r\n", 0x1A, "\n", 13::unsigned-big-32, "IHDR", 1::unsigned-big-32,
      1::unsigned-big-32, 8, 2, 0, 0, 0, 0::unsigned-big-32, 0::unsigned-big-32, "IEND",
      0::unsigned-big-32>>
  end

  defp jpeg, do: <<0xFF, 0xD8, 0xFF, 0xE0, "image", 0xFF, 0xD9>>

  defp webp do
    payload = <<"WEBP", "VP8 ", "image">>
    <<"RIFF", byte_size(payload)::unsigned-little-32, payload::binary>>
  end
end
