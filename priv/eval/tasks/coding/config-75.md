---
id: coding/config-75
title: "Multi"
description: "Please write a collaborative game development framework called Multi-Agent Shooter Framework (MASF)."
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
source: "marble/configs/coding_configs/config_75.yaml"
---

# Multi

Software Development Task:

Please write a collaborative game development framework called Multi-Agent Shooter Framework (MASF). MASF is a comprehensive system that enables multiple AI agents to work together in developing and enhancing a shooter game, focusing on both the frontend and backend aspects of the game. The system facilitates the creation of a dynamic and interactive game environment where agents can contribute to game mechanics, user interface design, and backend logic, ensuring a seamless and engaging experience for players.
1. Implementation requirements:
   - The frontend domain should be responsible for designing and implementing the user interface, including the game screen, scoreboards, and menus. The frontend should be developed using modern web technologies such as HTML5, CSS3, and JavaScript, and should be responsive to various screen sizes.
   - The backend domain should handle game logic, player management, and data storage. It should be built using a robust server-side framework like Node.js or Django, and should include a database (e.g., MongoDB or PostgreSQL) to store player data, game states, and leaderboard information.
   - The system should support real-time communication between the frontend and backend using WebSockets to ensure that game events and updates are synchronized across all connected clients. Additionally, the backend should provide APIs for the frontend to interact with, such as fetching player data, submitting scores, and updating game states.
   - The Multi-Agent Shooter Framework should include a collaboration layer that allows multiple AI agents to contribute to the game's development. Each agent should be able to specialize in a specific domain (e.g., one agent for frontend design, another for backend logic) and collaborate through a shared development environment. The framework should provide tools and APIs for agents to communicate, share code, and integrate their contributions seamlessly.
   - The game should feature a variety of shooting challenges, including target practice, enemy waves, and timed missions. Each challenge should have adjustable difficulty levels and provide players with feedback on their performance, such as accuracy and reaction time.
   - The system should include a robust testing and debugging environment to ensure that the game functions correctly and that the contributions from multiple agents are integrated without conflicts. The testing environment should support automated and manual testing, and should provide detailed logs and reports for troubleshooting.


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
