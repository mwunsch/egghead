defmodule Egghead.Eval.Prompts do
  @moduledoc """
  Evaluator prompts ported from MARBLE.

  Source: `marble/evaluator/evaluator_prompts.json` and
  `marble/evaluator/env_evaluation_prompts.json` at
  https://github.com/ulab-uiuc/MARBLE (MIT license).

  MARBLE is the reference implementation of MultiAgentBench, Zhu et al.,
  ACL 2025 (https://arxiv.org/abs/2503.01935). Prompts are copied verbatim
  with minimal formatting changes (EEx interpolation instead of Python
  `.format()`).

  Each function returns a prompt string ready to send to the Judge LLM.
  """

  @doc """
  KPI / milestone extraction prompt.

  Asks the judge to identify concrete milestones achieved in the
  transcript and attribute each to the agent ids that contributed. The
  model must respond with a JSON array of `{milestone, agents}`
  objects.
  """
  @spec kpi(String.t(), String.t(), [String.t()]) :: String.t()
  def kpi(task, agent_results, milestones) do
    milestones_block =
      case milestones do
        [] ->
          ""

        list ->
          "**Candidate milestones (use these as guidance, refine or add as needed):**\n" <>
            Enum.map_join(list, "\n", &"- #{&1}") <> "\n\n"
      end

    """

    [Context]
    **Task:**
    #{task}

    **Agent Results:**
    #{agent_results}

    #{milestones_block}[System]
    Analyze the results and identify concrete milestones achieved towards task completion. For each milestone:
    1. Provide a clear, specific description
    2. List the agent IDs that contributed to it

    You MUST respond in this exact JSON array format:
    [
      {
        "milestone": "specific achievement or progress made",
        "agents": ["agent1", "agent2"]
      }
    ]

    Rules:
    1. Each milestone must be a concrete, measurable achievement
    2. Only include agents that directly contributed
    3. Use exact agent IDs from the results
    4. Keep milestone descriptions under 100 characters
    5. If no progress was made, return an empty array: []

    [Question]
    Provide ONLY the JSON array. No explanation or additional text.
    """
  end

  @doc """
  Communication quality rating prompt (1-5).
  """
  @spec communication(String.t(), String.t()) :: String.t()
  def communication(task, communications) do
    """

    [Context]
    **Task:** #{task}

    **Communications:** #{communications}

    [System]
    Evaluate the communication quality between agents in the Graph structure. Focus on:

    - **Information Exchange:** Was relevant information effectively transmitted?
    - **Clarity:** Were intentions and messages clear?
    - **Task Assistance:** Did communication help task completion?
    - **Efficiency:** Was communication concise and purposeful?

    Rate on a 5-point scale:
    1. **1 point**: Poor communication with major failures.
    2. **2 points**: Significant issues in clarity or relevance.
    3. **3 points**: Adequate but required clarification.
    4. **4 points**: Effective with minor improvements needed.
    5. **5 points**: Clear, effective communication that maximized efficiency.

    [Question]
    You MUST respond with ONLY a JSON object in this EXACT format:
    {"rating": X}
    where X is a number between 1 and 5.

    Example valid responses:
    {"rating": 4}
    {"rating": 2}

    DO NOT include any other text, explanation, or formatting.
    """
  end

  @doc """
  Planning / self-coordination rating prompt (1-5).
  """
  @spec planning(String.t(), String.t(), String.t(), String.t()) :: String.t()
  def planning(summary, agent_profiles, agent_tasks, results) do
    """

    [Context]
    **Summary:** #{summary}

    **Agent Profiles:** #{agent_profiles}

    **Agent Tasks:** #{agent_tasks}

    **Results:** #{results}

    [System]
    Evaluate the effectiveness of agent self-coordination in the Graph structure. Focus on:

    - **Role Clarity:** Did agents understand their roles and responsibilities?
    - **Task Alignment:** Were tasks aligned with goals?
    - **Autonomy:** Did agents work independently without central oversight?

    Rate on a 5-point scale:
    1. **1 point**: Very poor self-coordination, with major inefficiencies.
    2. **2 points**: Frequent role confusion, causing inefficiencies.
    3. **3 points**: Moderate overlap or confusion in roles.
    4. **4 points**: Effective with minor role clarification needed.
    5. **5 points**: Clear roles, effective self-coordination.

    [Question]
    You MUST respond with ONLY a JSON object in this EXACT format:
    {"rating": X}
    where X is a number between 1 and 5.

    Example valid responses:
    {"rating": 4}
    {"rating": 2}

    DO NOT include any other text, explanation, or formatting.
    """
  end

  @doc """
  Research-task-specific evaluation: innovation / safety / feasibility.
  """
  @spec research(String.t(), String.t()) :: String.t()
  def research(task, result) do
    """

    [Context]
    Task:
    #{task}

    Result:
    #{result}

    [System]
    Evaluate the research idea on three aspects using a 5-point scale:
    - Innovation (1-5): Novelty and advancement
    - Safety (1-5): Ethical and legal considerations
    - Feasibility (1-5): Practicality and achievability

    Scale:
    5: Excellent
    4: Good
    3: Average
    2: Below Average
    1: Poor

    [Question]
    Provide your ratings in this exact JSON format:
    {
      "innovation": NUMBER,
      "safety": NUMBER,
      "feasibility": NUMBER
    }

    Do not include any other text or explanation.
    """
  end

  @doc """
  Bargaining-specific seller evaluation prompt.
  """
  @spec bargaining_seller(String.t(), String.t()) :: String.t()
  def bargaining_seller(task, result) do
    """
    [Context]
    Task:
    #{task}

    Result:
    #{result}

    [System]
    Please act as an impartial evaluator and assess the negotiation process **only for the seller** based on the provided context. Your evaluation should focus on the following three aspects:

    - **Effectiveness of Strategies**: Did the seller demonstrate well-reasoned strategies aligned with their goals?
    - **Progress and Outcome**: Was there significant progress toward reaching an agreement from the seller's perspective?
    - **Interaction Dynamics**: Were the seller's interactions with the buyer constructive and goal-oriented?

    Use the **5-point scale** below:

    1. **5 points**: Excellent
    2. **4 points**: Good
    3. **3 points**: Average
    4. **2 points**: Below Average
    5. **1 point**: Poor

    [Output Format]
    Output your ratings in the following JSON format:

    {
      "seller": {
        "effectiveness_of_strategies": rating,
        "progress_and_outcome": rating,
        "interaction_dynamics": rating
      }
    }
    """
  end

  @doc """
  Bargaining-specific buyer evaluation prompt.
  """
  @spec bargaining_buyer(String.t(), String.t()) :: String.t()
  def bargaining_buyer(task, result) do
    """
    [Context]
    Task:
    #{task}

    Result:
    #{result}

    [System]
    Please act as an impartial evaluator and assess the negotiation process **only for the buyer** based on the provided context. Your evaluation should focus on the following three aspects:

    - **Effectiveness of Strategies**: Did the buyer demonstrate well-reasoned strategies aligned with their goals?
    - **Progress and Outcome**: Was there significant progress toward reaching an agreement?
    - **Interaction Dynamics**: Were the buyer's interactions with the seller constructive and goal-oriented?

    Use the **5-point scale**:

    1. **5 points**: Excellent
    2. **4 points**: Good
    3. **3 points**: Average
    4. **2 points**: Below Average
    5. **1 point**: Poor

    [Output Format]
    {
      "buyer": {
        "effectiveness_of_strategies": rating,
        "progress_and_outcome": rating,
        "interaction_dynamics": rating
      }
    }
    """
  end
end
