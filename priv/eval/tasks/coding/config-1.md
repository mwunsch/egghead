---
id: coding/config-1
title: "Team Treasure Hunt"
description: "Please write a program called 'Team_Treasure_Hunt' that is a multiplayer action game where teams of players collaborate to navigate through a series of challenging environments, collect treasures, ..."
category: coding
difficulty: hard
required_capabilities: [records.read, fs.read, fs.write, shell.exec]
personas: [coding-creator, coding-extender, coding-optimizer]
dialogue_mode: open
milestones:
  - "Scaffolded an initial implementation with the expected file structure"
  - "Implemented at least the core feature from the task description"
  - "Added at least one test case or validation step"
  - "Handled at least one explicit edge case or invalid input"
  - "Produced a final artifact that runs without syntax errors"
  - "Demonstrated peer review and revision across multiple agents"
source: "marble/configs/coding_configs/config_1.yaml"
---

# Team Treasure Hunt

Software Development Task:

Please write a program called 'Team_Treasure_Hunt' that is a multiplayer action game where teams of players collaborate to navigate through a series of challenging environments, collect treasures, and solve puzzles to reach a final treasure chamber. Each team member has unique abilities that are essential for solving specific puzzles and overcoming obstacles. The game includes various environments such as forests, caves, and ancient ruins, each with its own set of challenges. The team that collects the most treasures and reaches the final chamber first wins the game.
1. Implementation requirements:
   - Implement a game engine that supports multiplayer functionalities, allowing up to four players per team.
   - Design different environments with varying levels of difficulty, including puzzles that require collaboration and the use of unique character abilities.
   - Create a set of unique character abilities, such as strength (for moving heavy objects), agility (for navigating tight spaces), intelligence (for solving complex puzzles), and stealth (for avoiding traps).
   - Develop a scoring system that rewards teams based on the number of treasures collected and the time taken to reach the final chamber.
   - Provide comprehensive test specifications, including input scenarios such as different player actions, expected outputs like the game state changes, and edge cases such as players leaving the game or failing to solve puzzles.
   - Ensure the game is robust and can handle unexpected inputs or behaviors from players, such as simultaneous actions or incorrect puzzle solutions.
   - Test the game with different team compositions and strategies to ensure balanced and fair gameplay.


2. Project structure:
   - solution.py (main implementation)

3. Development process:
   - Developer: Create the code.
   - Developer: Revise the code.
   - Developer: Optimize the code.

If there are multiple files, please put them all in solution.py, but remember to add the file name in the following format:
```python
# file_name_1.py
# your code here

# file_name_2.py
# your code here

# file_name_3.py
# your code here
```

Please work together to complete this task following software engineering best practices.
