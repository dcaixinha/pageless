defmodule Pageless.Library.ScanCoordinator do
  @moduledoc false

  use GenServer

  require Logger

  alias Pageless.Library
  alias Pageless.Library.{Scanner, Watcher, WatcherSupervisor}

  @periodic_reconcile_ms :timer.minutes(15)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def request_scan(library_or_id, source \\ :manual)
  def request_scan(%{id: id}, source), do: request_scan(id, source)
  def request_scan(id, source), do: GenServer.cast(__MODULE__, {:scan, id, source})

  def library_changed(library_id, scan? \\ false),
    do: GenServer.cast(__MODULE__, {:library_changed, library_id, scan?})

  def library_deleted(library_id), do: GenServer.cast(__MODULE__, {:library_deleted, library_id})
  def status, do: GenServer.call(__MODULE__, :status)

  @impl true
  def init(_opts) do
    watchers_enabled = Application.get_env(:pageless, :start_library_watchers, true)

    {:ok,
     %{
       running: %{},
       refs: %{},
       pending: %{},
       watchers: %{},
       watcher_refs: %{},
       watchers_enabled: watchers_enabled
     }, {:continue, :start_watchers}}
  end

  @impl true
  def handle_continue(:start_watchers, state) do
    state = if state.watchers_enabled, do: start_enabled_watchers(state), else: state
    schedule_periodic()
    {:noreply, state}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, Map.keys(state.running), state}

  @impl true
  def handle_cast({:scan, library_id, source}, state) do
    if state.watchers_enabled,
      do: {:noreply, queue_scan(state, library_id, source)},
      else: {:noreply, state}
  end

  def handle_cast({:library_changed, library_id, scan?}, state) do
    if state.watchers_enabled do
      state = state |> cancel_scan(library_id, :superseded) |> stop_watcher(library_id)
      library = Library.get_library(library_id)
      if library, do: Library.mark_books_outside_library_roots_missing(library)
      state = start_watcher(state, library)

      state =
        if (scan? and library) && library.auto_scan_on_file_changes,
          do: queue_scan(state, library_id, :library_update),
          else: state

      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_cast({:library_deleted, library_id}, state) do
    state = cancel_scan(state, library_id, :library_deleted)

    {:noreply,
     state
     |> stop_watcher(library_id)
     |> Map.update!(:pending, &Map.delete(&1, library_id))}
  end

  @impl true
  def handle_info({ref, _result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish_scan(state, ref)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.watcher_refs, ref) do
      {nil, _watcher_refs} ->
        if Map.has_key?(state.refs, ref) and reason != :normal do
          library_id = Map.fetch!(state.refs, ref)
          Logger.warning("Library scan task failed: #{inspect(reason)}")
          broadcast_scan_failed(library_id, reason)
        end

        {:noreply, finish_scan(state, ref)}

      {{library_id, pid}, watcher_refs} ->
        Logger.warning("Library watcher exited for #{library_id}: #{inspect(reason)}")

        watchers =
          if Map.get(state.watchers, library_id) == pid,
            do: Map.delete(state.watchers, library_id),
            else: state.watchers

        Process.send_after(self(), {:retry_watcher, library_id}, :timer.seconds(30))
        {:noreply, %{state | watchers: watchers, watcher_refs: watcher_refs}}
    end
  end

  def handle_info({:watcher_stopped, library_id, pid}, state) do
    state = remove_watcher_tracking(state, library_id, pid)

    Process.send_after(self(), {:retry_watcher, library_id}, :timer.seconds(30))
    {:noreply, state}
  end

  def handle_info({:retry_watcher, library_id}, state) do
    if state.watchers_enabled and not Map.has_key?(state.watchers, library_id) do
      {:noreply, start_watcher(state, Library.get_library(library_id))}
    else
      {:noreply, state}
    end
  end

  def handle_info(:periodic_reconcile, state) do
    state =
      if state.watchers_enabled do
        Library.list_libraries()
        |> Enum.filter(& &1.auto_scan_on_file_changes)
        |> Enum.reduce(state, fn library, state -> queue_scan(state, library.id, :periodic) end)
      else
        state
      end

    schedule_periodic()
    {:noreply, state}
  end

  defp start_scan(state, library_id, source) do
    case Library.get_library(library_id) do
      nil ->
        state

      library ->
        task =
          Task.Supervisor.async_nolink(Pageless.ScannerSupervisor, fn ->
            Scanner.scan(library,
              reconcile_missing: source != :startup,
              force_audio_metadata: source == :watcher
            )
          end)

        %{
          state
          | running: Map.put(state.running, library_id, task),
            refs: Map.put(state.refs, task.ref, library_id)
        }
    end
  end

  defp queue_scan(state, library_id, source) do
    if Map.has_key?(state.running, library_id) do
      pending_source = Map.get(state.pending, library_id)

      source =
        if pending_source in [:manual, :watcher, :library_update],
          do: pending_source,
          else: source

      %{state | pending: Map.put(state.pending, library_id, source)}
    else
      start_scan(state, library_id, source)
    end
  end

  defp cancel_scan(state, library_id, reason) do
    case Map.pop(state.running, library_id) do
      {nil, _running} ->
        state

      {task, running} ->
        Task.shutdown(task, :brutal_kill)
        if reason != :superseded, do: broadcast_scan_failed(library_id, reason)

        %{
          state
          | running: running,
            refs: Map.delete(state.refs, task.ref),
            pending: Map.delete(state.pending, library_id)
        }
    end
  end

  defp finish_scan(state, ref) do
    case Map.pop(state.refs, ref) do
      {nil, _refs} ->
        state

      {library_id, refs} ->
        state = %{state | refs: refs, running: Map.delete(state.running, library_id)}

        case Map.pop(state.pending, library_id) do
          {nil, _pending} -> state
          {source, pending} -> start_scan(%{state | pending: pending}, library_id, source)
        end
    end
  end

  defp start_enabled_watchers(state) do
    Enum.reduce(Library.list_libraries(), state, fn library, state ->
      state = start_watcher(state, library)

      if library.auto_scan_on_file_changes,
        do: start_scan(state, library.id, :startup),
        else: state
    end)
  end

  defp start_watcher(state, nil), do: state

  defp start_watcher(state, library) do
    if library.auto_scan_on_file_changes and library.folders != [] do
      case DynamicSupervisor.start_child(WatcherSupervisor, {Watcher, library.id}) do
        {:ok, pid} ->
          track_watcher(state, library.id, pid)

        {:error, {:already_started, pid}} ->
          track_watcher(state, library.id, pid)

        :ignore ->
          Process.send_after(self(), {:retry_watcher, library.id}, :timer.seconds(30))
          state

        {:error, reason} ->
          Logger.warning("Could not start watcher for library #{library.id}: #{inspect(reason)}")
          Process.send_after(self(), {:retry_watcher, library.id}, :timer.seconds(30))
          state
      end
    else
      state
    end
  end

  defp stop_watcher(state, library_id) do
    case Map.pop(state.watchers, library_id) do
      {nil, _watchers} ->
        state

      {pid, watchers} ->
        state = remove_watcher_tracking(%{state | watchers: watchers}, library_id, pid)
        if Process.alive?(pid), do: DynamicSupervisor.terminate_child(WatcherSupervisor, pid)
        state
    end
  end

  defp track_watcher(state, library_id, pid) do
    state = remove_watcher_tracking(state, library_id, Map.get(state.watchers, library_id))
    ref = Process.monitor(pid)

    %{
      state
      | watchers: Map.put(state.watchers, library_id, pid),
        watcher_refs: Map.put(state.watcher_refs, ref, {library_id, pid})
    }
  end

  defp remove_watcher_tracking(state, _library_id, nil), do: state

  defp remove_watcher_tracking(state, library_id, pid) do
    {refs_to_remove, watcher_refs} =
      Enum.split_with(state.watcher_refs, fn {_ref, value} -> value == {library_id, pid} end)

    Enum.each(refs_to_remove, fn {ref, _value} -> Process.demonitor(ref, [:flush]) end)

    %{
      state
      | watchers:
          if(Map.get(state.watchers, library_id) == pid,
            do: Map.delete(state.watchers, library_id),
            else: state.watchers
          ),
        watcher_refs: Map.new(watcher_refs)
    }
  end

  defp broadcast_scan_failed(library_id, reason) do
    message = {:scan_failed, %{library_id: library_id, reason: reason}}
    Phoenix.PubSub.broadcast(Pageless.PubSub, "library_scans", message)
    Phoenix.PubSub.broadcast(Pageless.PubSub, Scanner.topic(library_id), message)
  end

  defp schedule_periodic,
    do: Process.send_after(self(), :periodic_reconcile, @periodic_reconcile_ms)
end
