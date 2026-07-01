defmodule Pageless.Importers.Audiobookshelf.CLITest do
  use ExUnit.Case, async: true

  alias Pageless.Importers.Audiobookshelf.CLI

  describe "parse_args/1" do
    test "collects repeated path maps and libraries and defaults import_covers" do
      argv = [
        "--url",
        "http://abs",
        "--token",
        "t",
        "--user",
        "a@b.com",
        "--path-map",
        "/abs=/media",
        "--path-map",
        "/abs2=/media2",
        "--library",
        "Audiobooks",
        "--library",
        "Books",
        "--dry-run"
      ]

      assert {:ok, opts} = CLI.parse_args(argv)
      assert opts[:url] == "http://abs"
      assert opts[:token] == "t"
      assert opts[:user] == "a@b.com"
      assert opts[:dry_run] == true
      assert opts[:import_covers] == true
      assert opts[:path_maps] == [{"/abs", "/media"}, {"/abs2", "/media2"}]
      assert opts[:libraries] == ["Audiobooks", "Books"]
    end

    test "does not override an explicit --no-import-covers" do
      assert {:ok, opts} = CLI.parse_args(["--no-import-covers"])
      assert opts[:import_covers] == false
    end

    test "returns error on invalid path map" do
      assert {:error, message} = CLI.parse_args(["--path-map", "no-equals"])
      assert message =~ "Invalid --path-map"
    end

    test "returns error on unknown switch" do
      assert {:error, message} = CLI.parse_args(["--bogus", "x"])
      assert message =~ "Invalid options"
    end
  end

  describe "format_report/1" do
    test "dry-run report omits imported counts" do
      report = %{
        dry_run: true,
        totals: %{
          abs_libraries: 2,
          abs_items: 10,
          abs_collections: 0,
          abs_playlists: 0,
          matched: 3,
          unmatched: 7,
          ambiguous: 0
        },
        imported: %{
          metadata: 0,
          covers: 0,
          progress: 0,
          bookmarks: 0,
          collections: 0,
          playlists: 0,
          history: 0
        },
        unmatched: [%{id: "x", title: "Untitled", path: "/abs/x"}],
        ambiguous: []
      }

      lines = CLI.format_report(report)

      assert "Audiobookshelf import dry run" in lines
      assert "ABS libraries: 2" in lines
      assert "Matched: 3" in lines
      refute Enum.any?(lines, &String.starts_with?(&1, "Metadata updates:"))
      assert "Unmatched items:" in lines
      assert "  Untitled: /abs/x" in lines
    end

    test "completed report includes imported counts" do
      report = %{
        dry_run: false,
        totals: %{
          abs_libraries: 1,
          abs_items: 1,
          abs_collections: 0,
          abs_playlists: 0,
          matched: 1,
          unmatched: 0,
          ambiguous: 0
        },
        imported: %{
          metadata: 1,
          covers: 1,
          progress: 1,
          bookmarks: 0,
          collections: 0,
          playlists: 0,
          history: 0
        },
        unmatched: [],
        ambiguous: []
      }

      lines = CLI.format_report(report)

      assert "Audiobookshelf import complete" in lines
      assert "Metadata updates: 1" in lines
      assert "Progress rows imported: 1" in lines
      refute "Unmatched items:" in lines
    end
  end

  describe "main/2" do
    test "prints error message and returns error tuple when args are invalid" do
      assert {:error, message} = CLI.main(["--bogus"], fn _ -> :ok end)
      assert message =~ "Invalid options"
    end
  end
end
