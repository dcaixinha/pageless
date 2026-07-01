defmodule Pageless.Library.Sorting do
  @moduledoc """
  Pure sorting rules shared with the mobile client.
  """

  @ignored_prefix ~r/^(?:a|an|the)\s+/i
  @sql_ignored_prefix "^(a|an|the)[[:space:]]+"

  def title_key(title, false), do: title |> String.trim(" ") |> String.downcase()

  def title_key(title, true) do
    title
    |> String.trim(" ")
    |> String.replace(@ignored_prefix, "")
    |> String.downcase()
  end

  def sql_ignored_prefix, do: @sql_ignored_prefix
end
