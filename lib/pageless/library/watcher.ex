defmodule Pageless.Library.Watcher do
  @moduledoc false

  use GenServer

  require Logger

  alias Pageless.Library
  alias Pageless.Library.ScanCoordinator

  @debounce_ms 2_000
  @stability_ms 1_000
  @required_stable_checks 3
  @max_stability_checks 60
  @relevant_extensions ~w(.m4b .jpg .jpeg .png .webp)

  def start_link(library_id) do
    GenServer.start_link(__MODULE__, library_id, name: via(library_id))
  end

  def child_spec(library_id) do
    %{
      id: {__MODULE__, library_id},
      start: {__MODULE__, :start_link, [library_id]},
      restart: :temporary
    }
  end

  defp via(library_id), do: {:via, Registry, {Pageless.Library.WatcherRegistry, library_id}}

  @impl true
  def init(library_id) do
    library = Library.get_library!(library_id)
    roots = Enum.map(library.folders, &Path.expand(&1.path))

    case FileSystem.start_link(dirs: roots) do
      {:ok, watcher} ->
        FileSystem.subscribe(watcher)

        {:ok,
         %{
           library_id: library_id,
           roots: roots,
           watcher: watcher,
           paths: MapSet.new(),
           timer: nil,
           generation: 0
         }}

      {:error, reason} ->
        Logger.warning("Could not watch library #{library_id}: #{inspect(reason)}")
        {:stop, reason}

      :ignore ->
        Logger.warning("Could not watch library #{library_id}: backend unavailable")
        :ignore
    end
  end

  @impl true
  def handle_info({:file_event, watcher, {path, events}}, %{watcher: watcher} = state) do
    path = Path.expand(to_string(path))

    if relevant_path?(path, state.roots, events) do
      if state.timer, do: Process.cancel_timer(state.timer)
      generation = state.generation + 1
      timer = Process.send_after(self(), {:debounce, generation}, @debounce_ms)

      {:noreply,
       %{state | paths: MapSet.put(state.paths, path), timer: timer, generation: generation}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:file_event, watcher, :stop}, %{watcher: watcher} = state) do
    Logger.warning("Filesystem watcher stopped for library #{state.library_id}")
    send(ScanCoordinator, {:watcher_stopped, state.library_id, self()})
    {:stop, :normal, state}
  end

  def handle_info({:debounce, generation}, %{generation: generation} = state) do
    paths = MapSet.to_list(state.paths)
    snapshot = signatures(paths)
    Process.send_after(self(), {:stable, generation, paths, snapshot, 0, 0}, @stability_ms)
    {:noreply, %{state | timer: nil}}
  end

  def handle_info({:debounce, _generation}, state), do: {:noreply, state}

  def handle_info(
        {:stable, generation, paths, snapshot, attempt, stable_checks},
        %{generation: generation} = state
      ) do
    next_snapshot = signatures(paths)

    cond do
      next_snapshot == snapshot and stable_checks + 1 >= @required_stable_checks ->
        ScanCoordinator.request_scan(state.library_id, :watcher)
        {:noreply, %{state | paths: MapSet.new()}}

      attempt + 1 >= @max_stability_checks ->
        Logger.warning("Timed out waiting for library #{state.library_id} files to stabilize")
        {:noreply, %{state | paths: MapSet.new()}}

      true ->
        stable_checks = if next_snapshot == snapshot, do: stable_checks + 1, else: 0

        Process.send_after(
          self(),
          {:stable, generation, paths, next_snapshot, attempt + 1, stable_checks},
          @stability_ms
        )

        {:noreply, state}
    end
  end

  def handle_info({:stable, _generation, _paths, _snapshot, _attempt, _stable_checks}, state),
    do: {:noreply, state}

  def relevant_path?(path, roots, events \\ []) do
    path = Path.expand(path)
    roots = Enum.map(roots, &Path.expand/1)
    within_root? = Enum.any?(roots, &(path == &1 or String.starts_with?(path, &1 <> "/")))
    basename = String.downcase(Path.basename(path))
    extension = String.downcase(Path.extname(path))

    within_root? and not String.contains?(basename, ".tmp-") and
      (basename == "metadata.json" or extension in @relevant_extensions or extension == "" or
         :is_dir in events or :isdir in events)
  end

  defp signatures(paths), do: Map.new(paths, &{&1, signature(&1)})

  defp signature(path) do
    case File.stat(path, time: :posix) do
      {:ok, stat} -> {stat.type, stat.size, stat.mtime}
      {:error, :enoent} -> :missing
      {:error, reason} -> {:error, reason}
    end
  end
end
