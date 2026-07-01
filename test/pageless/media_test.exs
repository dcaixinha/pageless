defmodule Pageless.MediaTest do
  use ExUnit.Case, async: true

  alias Pageless.Media

  setup do
    id = Ecto.UUID.generate()
    on_exit(fn -> Media.delete_covers(id) end)
    %{id: id}
  end

  test "store_cover/3 writes cover data and returns the path", %{id: id} do
    dest = Media.store_cover(id, "binary-data", "png")

    assert File.read!(dest) == "binary-data"
    assert Path.extname(dest) == ".png"
    assert String.contains?(dest, id)
  end

  test "store_cover/3 normalizes unknown extensions to jpg", %{id: id} do
    dest = Media.store_cover(id, "x", "gif")
    assert Path.extname(dest) == ".jpg"
  end

  test "store_cover/3 replaces any prior cover", %{id: id} do
    Media.store_cover(id, "old", "png")
    dest = Media.store_cover(id, "new", "jpg")

    # Only the new file should remain.
    covers = Media.covers_path() |> Path.join("#{id}.*") |> Path.wildcard()
    assert covers == [dest]
  end

  test "copy_cover/2 copies a file into the media dir", %{id: id} do
    src = Path.join(System.tmp_dir!(), "cover_#{System.unique_integer([:positive])}.png")
    File.write!(src, "img")
    on_exit(fn -> File.rm(src) end)

    dest = Media.copy_cover(id, src)
    assert File.read!(dest) == "img"
    assert Path.extname(dest) == ".png"
  end

  test "delete_covers/1 removes all covers for a book", %{id: id} do
    Media.store_cover(id, "x", "jpg")
    Media.delete_covers(id)
    assert Media.covers_path() |> Path.join("#{id}.*") |> Path.wildcard() == []
  end
end
