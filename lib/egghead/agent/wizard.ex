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
        capabilities: ["search", "record_read"],
        instructions: "You are Scout..."
      })
  """

  @valid_capabilities ~w(record_read record_append record_modify search)

  @type params :: %{
          name: String.t(),
          model: String.t(),
          tags: [String.t()],
          capabilities: [String.t()],
          instructions: String.t()
        }

  @doc "Returns the list of valid capability strings."
  @spec valid_capabilities() :: [String.t()]
  def valid_capabilities, do: @valid_capabilities

  @doc """
  Creates an agent record from the given params.

  Validates inputs, builds a `class: agent` record, and writes it
  to the record store. Returns `{:ok, record}` or `{:error, errors}`
  where errors is a map of `%{field => [messages]}`.
  """
  @spec create(params()) :: {:ok, Egghead.Record.t()} | {:error, map()}
  def create(params) do
    with :ok <- validate(params) do
      attrs = %{
        id: "agents/#{params.name}",
        title: String.capitalize(params.name),
        class: :agent,
        tags: Enum.uniq(["agent" | params[:tags] || []]),
        body: params.instructions || template(params.name),
        meta: %{
          "model" => params.model,
          "capabilities" => params[:capabilities] || []
        }
      }

      Egghead.create_record(attrs)
    end
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

  @doc "Capability labels for interactive display."
  @spec capability_labels() :: [{String.t(), String.t()}]
  def capability_labels do
    [
      {"Search the record store", "search"},
      {"Read full records", "record_read"},
      {"Create new records", "record_append"},
      {"Modify existing records", "record_modify"}
    ]
  end

  # --- Validation ---

  defp validate(params) do
    errors =
      %{}
      |> validate_name(params[:name])
      |> validate_model(params[:model])
      |> validate_capabilities(params[:capabilities])
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

  defp validate_capabilities(errors, nil), do: errors
  defp validate_capabilities(errors, []), do: errors

  defp validate_capabilities(errors, caps) when is_list(caps) do
    invalid = Enum.reject(caps, &(&1 in @valid_capabilities))

    if invalid == [] do
      errors
    else
      Map.put(errors, :capabilities, ["invalid capabilities: #{Enum.join(invalid, ", ")}"])
    end
  end

  defp validate_capabilities(errors, _), do: Map.put(errors, :capabilities, ["must be a list"])

  defp validate_instructions(errors, nil), do: errors
  defp validate_instructions(errors, ""), do: Map.put(errors, :instructions, ["cannot be empty"])
  defp validate_instructions(errors, _), do: errors
end
