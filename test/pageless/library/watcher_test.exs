defmodule Pageless.Library.WatcherTest do
  use ExUnit.Case, async: true

  alias Pageless.Library.Watcher

  test "relevant_path?/2 accepts catalog files and directories within library roots" do
    root = Path.join(System.tmp_dir!(), "watcher-root")

    assert Watcher.relevant_path?(Path.join(root, "Book/audio.M4B"), [root])
    assert Watcher.relevant_path?(Path.join(root, "Book/metadata.json"), [root])
    assert Watcher.relevant_path?(Path.join(root, "Book/cover.webp"), [root])
    assert Watcher.relevant_path?(Path.join(root, "New Book"), [root])
    assert Watcher.relevant_path?(Path.join(root, "Book 1.0"), [root], [:renamed, :is_dir])
    assert Watcher.relevant_path?(Path.join(root, "Book 2.0"), [root], [:renamed, :isdir])
  end

  test "relevant_path?/2 rejects unrelated, temporary, and outside files" do
    root = Path.join(System.tmp_dir!(), "watcher-root")

    refute Watcher.relevant_path?(Path.join(root, "Book/notes.txt"), [root])
    refute Watcher.relevant_path?(Path.join(root, "Book/metadata.json.tmp-1"), [root])
    refute Watcher.relevant_path?(Path.join(System.tmp_dir!(), "other/audio.m4b"), [root])
  end
end
