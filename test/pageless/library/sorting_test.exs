defmodule Pageless.Library.SortingTest do
  use ExUnit.Case, async: true

  alias Pageless.Library.Sorting

  test "title_key/2 preserves prefixes when disabled" do
    assert Sorting.title_key("  The Hobbit  ", false) == "the hobbit"
  end

  test "title_key/2 removes supported whole-word prefixes when enabled" do
    assert Sorting.title_key("  A Wizard of Earthsea  ", true) == "wizard of earthsea"
    assert Sorting.title_key("an Ember in the Ashes", true) == "ember in the ashes"
    assert Sorting.title_key("THE Left Hand of Darkness", true) == "left hand of darkness"
    assert Sorting.title_key("Theology", true) == "theology"
  end
end
