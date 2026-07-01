defmodule Pageless.Library.PublishedDateTest do
  use ExUnit.Case, async: true

  alias Pageless.Library.PublishedDate

  doctest PublishedDate

  describe "parse/1" do
    test "parses a full ISO date" do
      assert PublishedDate.parse("2014-11-25") == ~D[2014-11-25]
    end

    test "coerces year+month to the first of the month" do
      assert PublishedDate.parse("2015-04") == ~D[2015-04-01]
    end

    test "coerces a bare year to January 1st" do
      assert PublishedDate.parse("2021") == ~D[2021-01-01]
    end

    test "accepts an integer year" do
      assert PublishedDate.parse(2021) == ~D[2021-01-01]
    end

    test "accepts a Date struct" do
      assert PublishedDate.parse(~D[2000-06-15]) == ~D[2000-06-15]
    end

    test "takes the date portion of a full timestamp" do
      assert PublishedDate.parse("2014-11-25T00:00:00Z") == ~D[2014-11-25]
    end

    test "returns nil for blank or nonsense values" do
      assert PublishedDate.parse(nil) == nil
      assert PublishedDate.parse("") == nil
      assert PublishedDate.parse("   ") == nil
      assert PublishedDate.parse("nonsense") == nil
    end

    test "returns nil for an impossible date" do
      assert PublishedDate.parse("2021-13-40") == nil
    end
  end
end
