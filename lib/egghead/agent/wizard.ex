defmodule Egghead.Agent.Wizard do
  @moduledoc """
  Programmatic agent creation.

  API-first — the interactive CLI, TUI slash commands, and other agents
  all call `create/1`. The interactive CLI layer adds the $EDITOR flow
  and model picker on top.

  ## Example

      Egghead.Agent.Wizard.create(%{
        name: "scout",
        model: "anthropic/claude-sonnet-4-6",
        tags: ["research", "exploration"],
        capabilities: ["records.read", "records.create"],
        instructions: "You are Scout..."
      })

  Or with the `access:` shortcut for the common records-capability
  bundles:

      Egghead.Agent.Wizard.create(%{
        name: "scribe",
        model: "anthropic/claude-haiku-4-5",
        access: "rw",
        instructions: "You are Scribe..."
      })
  """

  alias Egghead.Capability.Catalog

  @type params :: %{
          optional(:capabilities) => [String.t()],
          optional(:access) => String.t(),
          optional(:sandbox) => String.t(),
          name: String.t(),
          model: String.t(),
          tags: [String.t()],
          instructions: String.t()
        }

  @doc "Returns the list of known capability strings (resource.verb)."
  @spec valid_capabilities() :: [String.t()]
  def valid_capabilities do
    Enum.map(Catalog.all(), fn {r, v, _} -> "#{r}.#{v}" end)
  end

  @doc """
  Creates an agent record from the given params.

  Validates inputs, builds a `class: agent` record, and writes it
  to the record store. Returns `{:ok, record}` or `{:error, errors}`
  where errors is a map of `%{field => [messages]}`.
  """
  @spec create(params()) :: {:ok, Egghead.Record.t()} | {:error, map()}
  def create(params) do
    # Title keeps the raw user input ("Capability Test"); id uses the
    # slug ("capability-test"). This way the display name stays
    # readable while the path stays URL/shell-safe.
    original_name = params[:name]
    slug = slugify(original_name)
    params = Map.put(params, :name, slug)

    with :ok <- validate(params) do
      meta =
        %{"model" => params.model}
        |> maybe_put("capabilities", params[:capabilities])
        |> maybe_put("access", params[:access])
        |> maybe_put("sandbox", params[:sandbox])

      attrs = %{
        id: "agents/#{slug}",
        title: title_case(original_name),
        class: :agent,
        tags: Enum.uniq(["agent" | params[:tags] || []]),
        body: params.instructions || template(slug),
        meta: meta
      }

      Egghead.create_record(attrs)
    end
  end

  # Omit the meta key entirely when the caller didn't provide a value.
  # This lets `Record.Agent.parse_capabilities/1` apply its load-time
  # default (`records.read`) instead of being forced to an explicit
  # empty list.
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc """
  Normalizes a user-entered name into an id-safe slug:
  lowercase, spaces and punctuation → hyphens, strip leading/trailing
  hyphens, collapse runs.

  Returns `nil` for nil input so downstream validation can flag it.
  """
  @spec slugify(String.t() | nil) :: String.t() | nil
  def slugify(nil), do: nil

  def slugify(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]+/, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
  end

  defp title_case(nil), do: nil

  defp title_case(name) do
    name
    |> String.split(~r/[\s_-]+/, trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  @doc """
  Returns a scaffold template for the agent's instructions,
  suitable for opening in `$EDITOR`.
  """
  @spec template(String.t()) :: String.t()
  def template(name) do
    cap_name = String.capitalize(name)

    """
    # #{cap_name}

    You are #{cap_name}, an agent in the Egghead record store.

    ## Role

    (What is this agent's purpose?)

    ## Behavior

    (How should it approach tasks? What tone should it use?)

    ## Focus areas

    (What parts of the record graph does it care about?)
    """
  end

  @doc "Capability labels for interactive display, sorted by risk (low → high)."
  @spec capability_labels() :: [{String.t(), String.t()}]
  def capability_labels do
    Catalog.all()
    |> Enum.sort_by(fn {r, v, %{risk: risk}} ->
      risk_order = %{low: 0, medium: 1, high: 2}
      {Map.get(risk_order, risk, 1), "#{r}.#{v}"}
    end)
    |> Enum.map(fn {r, v, %{short: short}} -> {short, "#{r}.#{v}"} end)
  end

  # --- Validation ---

  defp validate(params) do
    errors =
      %{}
      |> validate_name(params[:name])
      |> validate_model(params[:model])
      |> validate_capabilities(params[:capabilities])
      |> validate_access(params[:access])
      |> validate_sandbox(params[:sandbox])
      |> validate_instructions(params[:instructions])

    if errors == %{}, do: :ok, else: {:error, errors}
  end

  defp validate_name(errors, nil), do: Map.put(errors, :name, ["is required"])
  defp validate_name(errors, ""), do: Map.put(errors, :name, ["is required"])

  defp validate_name(errors, name) when is_binary(name) do
    cond do
      not Regex.match?(~r/^[a-z][a-z0-9_-]*$/, name) ->
        Map.put(errors, :name, ["must be lowercase alphanumeric with hyphens/underscores"])

      String.length(name) > 64 ->
        Map.put(errors, :name, ["must be 64 characters or fewer"])

      true ->
        errors
    end
  end

  defp validate_name(errors, _), do: Map.put(errors, :name, ["must be a string"])

  defp validate_model(errors, nil), do: Map.put(errors, :model, ["is required"])
  defp validate_model(errors, ""), do: Map.put(errors, :model, ["is required"])
  defp validate_model(errors, _model), do: errors

  defp validate_capabilities(errors, caps) do
    case Egghead.Capability.Validate.validate(caps) do
      :ok ->
        errors

      {:error, issues} ->
        messages = Enum.map(issues, &format_issue/1)
        Map.put(errors, :capabilities, messages)
    end
  end

  defp validate_access(errors, nil), do: errors

  defp validate_access(errors, value) do
    if Egghead.Record.Agent.valid_access?(value) do
      errors
    else
      Map.put(errors, :access, ["must be \"r\", \"w\", or \"rw\" — got #{inspect(value)}"])
    end
  end

  defp validate_sandbox(errors, nil), do: errors
  defp validate_sandbox(errors, ""), do: errors
  defp validate_sandbox(errors, value) when is_binary(value), do: errors

  defp validate_sandbox(errors, value),
    do: Map.put(errors, :sandbox, ["must be a string path — got #{inspect(value)}"])

  defp format_issue(%{problem: problem, suggestion: nil}), do: problem

  defp format_issue(%{problem: problem, suggestion: suggestion}),
    do: "#{problem} (did you mean `#{suggestion}`?)"

  defp validate_instructions(errors, nil), do: errors
  defp validate_instructions(errors, ""), do: Map.put(errors, :instructions, ["cannot be empty"])
  defp validate_instructions(errors, _), do: errors
end
