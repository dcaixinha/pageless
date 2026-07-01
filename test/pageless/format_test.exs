defmodule Pageless.FormatTest do
  use ExUnit.Case, async: true

  doctest Pageless.Format

  alias Pageless.Format

  test "clock/1 formats with and without hours" do
    assert Format.clock(0) == "0:00"
    assert Format.clock(65) == "1:05"
    assert Format.clock(3661) == "1:01:01"
  end

  test "duration/1 handles nil" do
    assert Format.duration(nil) == "0m"
  end

  test "hms/1 handles nil" do
    assert Format.hms(nil) == "00:00:00"
  end

  test "parse_hms/1 round-trips with hms/1" do
    for seconds <- [0, 5, 65, 3725, 55_121] do
      assert Format.parse_hms(Format.hms(seconds)) == seconds * 1.0
    end
  end

  test "parse_hms/1 returns nil for invalid input" do
    assert Format.parse_hms("") == nil
    assert Format.parse_hms("1:2:3:4") == nil
    assert Format.parse_hms("ab:cd") == nil
    assert Format.parse_hms(nil) == nil
  end

  test "count/2 pluralizes the noun for any count other than one" do
    assert Format.count(0, "book") == "0 books"
    assert Format.count(1, "book") == "1 book"
    assert Format.count(2, "book") == "2 books"
  end

  test "count/3 uses an explicit plural for irregular nouns" do
    assert Format.count(1, "series", "series") == "1 series"
    assert Format.count(3, "series", "series") == "3 series"
  end

  test "date/2 supports every configured English date format" do
    date = ~D[2014-03-25]

    assert Format.date(date, "MM/dd/yyyy") == "03/25/2014"
    assert Format.date(date, "dd/MM/yyyy") == "25/03/2014"
    assert Format.date(date, "dd.MM.yyyy") == "25.03.2014"
    assert Format.date(date, "yyyy-MM-dd") == "2014-03-25"
    assert Format.date(date, "MMM do, yyyy") == "Mar 25th, 2014"
    assert Format.date(date, "MMMM do, yyyy") == "March 25th, 2014"
    assert Format.date(date, "dd MMM yyyy") == "25 Mar 2014"
    assert Format.date(date, "dd MMMM yyyy") == "25 March 2014"
  end

  test "date/2 handles English ordinal exceptions" do
    assert Format.date(~D[2026-01-01], "MMM do, yyyy") == "Jan 1st, 2026"
    assert Format.date(~D[2026-01-02], "MMM do, yyyy") == "Jan 2nd, 2026"
    assert Format.date(~D[2026-01-03], "MMM do, yyyy") == "Jan 3rd, 2026"
    assert Format.date(~D[2026-01-11], "MMM do, yyyy") == "Jan 11th, 2026"
    assert Format.date(~D[2026-01-12], "MMM do, yyyy") == "Jan 12th, 2026"
    assert Format.date(~D[2026-01-13], "MMM do, yyyy") == "Jan 13th, 2026"
    assert Format.date(~D[2026-01-21], "MMM do, yyyy") == "Jan 21st, 2026"
  end

  test "time/3 supports 12-hour, 24-hour, and seconds precision" do
    midnight = ~U[2026-07-21 00:05:09Z]
    noon = ~U[2026-07-21 12:05:09Z]

    assert Format.time(midnight, "HH:mm") == "00:05"
    assert Format.time(noon, "HH:mm", seconds: true) == "12:05:09"
    assert Format.time(midnight, "h:mma") == "12:05AM"
    assert Format.time(noon, "h:mma", seconds: true) == "12:05:09PM"
  end

  test "datetime/4 combines the selected formats" do
    assert Format.datetime(~U[2026-07-21 18:30:00Z], "dd/MM/yyyy", "HH:mm") ==
             "21/07/2026 18:30"
  end
end
