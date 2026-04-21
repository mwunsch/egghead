---
id: coding/config-85
title: "SportGame Collaborative Analytics"
description: "Please write a program called SportGame_Collaborative_Analytics that facilitates the collaborative analysis of sports game data among multiple agents."
category: coding
difficulty: medium
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
source: "marble/configs/coding_configs/config_85.yaml"
---

# SportGame Collaborative Analytics

Software Development Task:

Please write a program called SportGame_Collaborative_Analytics that facilitates the collaborative analysis of sports game data among multiple agents. SportGame_Collaborative_Analytics is a software application that enables a team of analysts to input, track, and analyze various performance metrics of athletes in real-time during a sports game. The application supports real-time collaboration, allowing multiple analysts to work on the same dataset simultaneously, and provides tools for generating reports and visualizations.
1. Implementation requirements:
   - The program should support the creation of user accounts for analysts, with authentication to ensure secure access.
   - The application must allow analysts to input real-time data such as player names, scores, assists, and other relevant game metrics during the game.
   - The system should provide real-time collaboration features, enabling multiple analysts to work on the same dataset simultaneously. Changes made by one analyst should be immediately visible to others.
   - The application should include a feature to generate detailed reports and visualizations based on the input data, such as player performance charts and game statistics summaries.
   - The program must include a comprehensive set of test cases to validate the functionality of the real-time collaboration feature, including scenarios where multiple analysts are simultaneously inputting data, updating existing records, and generating reports.
   - Test cases should cover edge cases such as network latency, data conflicts, and user disconnections to ensure the system's robustness and reliability.
   - The application should have a user-friendly interface that allows analysts to easily navigate and interact with the data, and it should provide clear feedback on the status of data updates and reports.


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
