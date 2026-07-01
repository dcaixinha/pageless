defmodule Pageless.Library.ProbeTest do
  use ExUnit.Case, async: true

  alias Pageless.Library.Probe

  @fixture Path.expand(
             "../../support/fixtures/media/The Test Book/The Test Book.m4b",
             __DIR__
           )

  describe "probe/1" do
    test "returns normalized metadata for a real media file" do
      assert {:ok, probe} = Probe.probe(@fixture)
      assert is_float(probe.duration)
      assert probe.duration > 0
      assert is_map(probe.tags)
      assert is_list(probe.chapters)
    end

    test "returns {:error, :ffprobe_not_found} when the binary is missing" do
      System.put_env("FFPROBE_BIN", "ffprobe-does-not-exist")
      on_exit(fn -> System.delete_env("FFPROBE_BIN") end)

      assert {:error, :ffprobe_not_found} = Probe.probe(@fixture)
    end
  end

  describe "extract_cover/2" do
    test "returns {:error, :ffmpeg_not_found} when the binary is missing" do
      System.put_env("FFMPEG_BIN", "ffmpeg-does-not-exist")
      on_exit(fn -> System.delete_env("FFMPEG_BIN") end)

      dest = Path.join(System.tmp_dir!(), "cover-#{System.unique_integer([:positive])}.jpg")
      assert {:error, :ffmpeg_not_found} = Probe.extract_cover(@fixture, dest)
    end
  end
end
