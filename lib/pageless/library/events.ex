defmodule Pageless.Library.Events do
  @moduledoc false

  alias Pageless.Accounts
  alias Pageless.Accounts.Scope

  @all_topic "catalog:all"

  def subscribe(%Scope{} = scope) do
    case Accounts.accessible_library_ids(scope) do
      :all -> Phoenix.PubSub.subscribe(Pageless.PubSub, @all_topic)
      ids -> Enum.each(ids, &Phoenix.PubSub.subscribe(Pageless.PubSub, library_topic(&1)))
    end
  end

  def broadcast_changed(library_id, upserted_book_ids, missing_book_ids) do
    payload = %{
      library_id: library_id,
      upserted_book_ids: Enum.uniq(upserted_book_ids),
      missing_book_ids: Enum.uniq(missing_book_ids)
    }

    message = {:catalog_changed, payload}
    Phoenix.PubSub.broadcast(Pageless.PubSub, @all_topic, message)
    Phoenix.PubSub.broadcast(Pageless.PubSub, library_topic(library_id), message)
  end

  defp library_topic(library_id), do: "catalog:library:#{library_id}"
end
