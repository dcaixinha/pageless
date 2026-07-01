defmodule Pageless.Library.ChaptersTest do
  use ExUnit.Case, async: true

  doctest Pageless.Library.Chapters

  alias Pageless.Library.Chapters

  test "current_index/2 returns nil for no chapters" do
    assert Chapters.current_index([], 42.0) == nil
  end

  test "current_index/2 finds the containing chapter" do
    assert Chapters.current_index(chapters(), 0.0) == 0
    assert Chapters.current_index(chapters(), 499.9) == 0
    assert Chapters.current_index(chapters(), 500.0) == 1
    assert Chapters.current_index(chapters(), 1200.0) == 2
  end

  test "current_index/2 clamps a position past the end to the last chapter" do
    assert Chapters.current_index(chapters(), 5000.0) == 2
  end

  test "current_index/2 clamps a negative position to the first chapter" do
    assert Chapters.current_index(chapters(), -10.0) == 0
  end

  defp chapters do
    [
      %{start_seconds: 0.0, end_seconds: 500.0},
      %{start_seconds: 500.0, end_seconds: 1000.0},
      %{start_seconds: 1000.0, end_seconds: 1500.0}
    ]
  end
end
