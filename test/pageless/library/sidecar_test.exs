defmodule Pageless.Library.SidecarTest do
  use ExUnit.Case, async: true

  alias Pageless.Library.Sidecar

  @tmp System.tmp_dir!()

  test "read/1 returns nil for missing file" do
    assert Sidecar.read(Path.join(@tmp, "does_not_exist.json")) == nil
  end

  test "read/1 returns nil for invalid JSON" do
    path = write_json("{not json")
    assert Sidecar.read(path) == nil
  end

  test "parses nested metadata with object authors and series" do
    path =
      write_json("""
      {
        "metadata": {
          "title": "Book",
          "authors": [{"name": "A"}, {"name": "B"}],
          "series": [{"name": "S", "sequence": "2"}],
          "publishedYear": "1999"
        }
      }
      """)

    meta = Sidecar.read(path)
    assert meta.title == "Book"
    assert meta.authors == ["A", "B"]
    assert meta.series == [%{name: "S", sequence: "2"}]
    assert meta.published_date == ~D[1999-01-01]
  end

  test "parses flat metadata with string authors and series" do
    path =
      write_json("""
      {
        "title": "Flat",
        "author": "Solo Author",
        "series": "Lonely Series",
        "publishedDate": "2010-05-01"
      }
      """)

    meta = Sidecar.read(path)
    assert meta.title == "Flat"
    assert meta.authors == ["Solo Author"]
    assert meta.series == [%{name: "Lonely Series", sequence: nil}]
    assert meta.published_date == ~D[2010-05-01]
  end

  test "parses comma-separated author strings" do
    path = write_json(~s({"metadata": {"authors": "One, Two, Three"}}))
    meta = Sidecar.read(path)
    assert meta.authors == ["One", "Two", "Three"]
  end

  test "preserves narrator arrays and treats scalar names as atomic" do
    array_path =
      write_json(~s({"metadata": {"narrators": ["Primary Reader", {"name": "Doe, Jane"}]}}))

    scalar_path = write_json(~s({"metadata": {"narrator": "Doe, Jane"}}))

    assert Sidecar.read(array_path).narrators == ["Primary Reader", "Doe, Jane"]
    assert Sidecar.read(scalar_path).narrators == ["Doe, Jane"]
  end

  test "parses genres from arrays and strings" do
    path = write_json(~s({"metadata": {"genres": [{"name": "History"}, "Science:Memoir"]}}))
    meta = Sidecar.read(path)
    assert meta.genres == ["History", "Science", "Memoir"]
  end

  test "parses chapters" do
    path =
      write_json("""
      {"chapters": [{"start": 0, "end": 10, "title": "Intro"}]}
      """)

    meta = Sidecar.read(path)
    assert meta.chapters == [%{title: "Intro", start: 0.0, end: 10.0}]
  end

  defp write_json(content) do
    path = Path.join(@tmp, "metadata_#{System.unique_integer([:positive])}.json")
    File.write!(path, content)
    on_exit_path(path)
    path
  end

  defp on_exit_path(path), do: ExUnit.Callbacks.on_exit(fn -> File.rm(path) end)
end
