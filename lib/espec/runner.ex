defmodule ESpec.Runner do
  @moduledoc """
  Defines functions which runs the examples.
  Uses GenServer behavior.
  """
  use GenServer

  @doc "Starts the `ESpec.Runner` server"
  def start do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "Initiate the `ESpec.Runner` server with specs and options"
  def init(_args) do
    state = %{specs: ESpec.specs, opts: ESpec.Configuration.all}
    {:ok, state}
  end

  @doc "Runs all examples."
  def run, do: GenServer.call(__MODULE__, :run, :infinity)

  @doc false
  def stop, do: GenServer.call(__MODULE__, :stop)

  @doc false
  def handle_call(:run, _pid, state) do
    result = do_run(state[:specs], state[:opts])
    {:reply, result, state}
  end

  @doc false
  def handle_call(:stop, _pid, state) do
    {:stop, :normal, :ok, []}
  end

  defp do_run(specs, opts) do
    if ESpec.Configuration.get(:order) do
      examples = run_in_order(specs, opts)
    else
      examples = run_in_random(specs, opts)
    end
    ESpec.Configuration.add([finish_specs_time: :os.timestamp])
    ESpec.Output.print_result(examples)
    !Enum.any?(ESpec.Example.failure(examples))
  end

  defp run_in_order(specs, opts) do
    specs |> Enum.reverse
    |> Enum.map(fn(module) ->
      filter(module.examples, opts)
      |> run_examples
    end)
    |> List.flatten
  end

  defp run_in_random(specs, opts) do
    examples = Enum.map(specs, fn(module) ->
      filter(module.examples, opts)
    end) |> List.flatten |> Enum.shuffle

    run_examples(examples)
  end

  @doc "Runs examples."
  def run_examples(examples) do
    {async, sync} = partition_async(examples)
    run_async(async) ++ run_sync(sync)
  end

  @doc false
  def partition_async(examples) do
    Enum.partition(examples, &ESpec.Example.extract_option(&1, :async) === true)
  end

  defp run_async(examples) do
    examples
    |> Enum.map(&Task.async(fn -> ESpec.ExampleRunner.run(&1) end))
    |> Enum.map(&Task.await(&1, :infinity))
  end

  defp run_sync(examples) do
    Enum.map(examples, &ESpec.ExampleRunner.run(&1))
  end

  @doc false
  def filter(examples, opts) do
    file_opts = opts[:file_opts] || []
    examples = filter_shared(examples)

    if Enum.any?(file_opts), do: examples = file_opts_filter(examples, file_opts)
    if opts[:focus], do: examples = filter_focus(examples)
    if opts[:only], do: examples = filter_only(examples, opts[:only])
    if opts[:exclude], do: examples = filter_only(examples, opts[:exclude], true)

    examples
  end

  defp filter_shared(examples), do: Enum.filter(examples, &(!&1.shared))

  defp file_opts_filter(examples, file_opts) do
    grouped_by_file = Enum.group_by(examples, fn(example) -> example.file end)
    filtered = Enum.reduce(grouped_by_file, [], fn({file, exs}, acc) ->
      opts = opts_for_file(file, file_opts)
      line = Keyword.get(opts, :line)
      if line do
        closest = get_closest(Enum.map(exs, &(&1.line)), line)
        acc ++ Enum.filter(exs, &(&1.line == closest))
      else
        acc ++ exs
      end
    end)
    filtered
  end

  defp get_closest(arr, value) do
    arr = Enum.sort(arr)
    diff = abs(value - hd(arr))
    {_d, el} = Enum.reduce(arr, {diff, hd(arr)}, fn(el, {d, e}) ->
      diff = abs(value - el)
      if diff < d, do: {diff, el}, else: {d, e}
    end)
    el
  end

  defp opts_for_file(file, opts_list) do
    case opts_list |> Enum.find(fn {k, _} -> k == file end) do
      {_file, opts} -> opts
      nil -> []
    end
  end

  defp filter_focus(examples) do
    Enum.filter(examples, fn(example) ->
      contexts = ESpec.Example.extract_contexts(example)
      example.opts[:focus] || Enum.any?(contexts, &(&1.opts[:focus]))
    end)
  end

  defp filter_only(examples, only, reverse \\ false) do
    [key, value] = extract_opts(only)
    Enum.filter(examples, fn(example) ->
      contexts = ESpec.Example.extract_contexts(example)
      key = String.to_atom(key)
      example_tag_value = example.opts[key]
      context_tag_values = Enum.map(contexts, &(&1.opts[key]))
      tag_values =  Enum.filter([example_tag_value | context_tag_values], &(&1))
      if reverse do
        if Enum.empty?(tag_values), do: true, else: !is_any_with_tag?(tag_values, value)
      else
        is_any_with_tag?(tag_values, value)
      end
    end)
  end

  defp is_any_with_tag?(tag_values, value) do
    Enum.any?(tag_values, fn(tag) ->
      if is_atom(tag) do
        if value, do: Atom.to_string(tag) == value, else: tag
      else
        if value, do: tag == value, else: tag
      end
    end)
  end

  defp extract_opts(key_value) do
    if String.match?(key_value, ~r/:/) do
      String.split(key_value, ":")
    else
      [key_value, false]
    end
  end
end
