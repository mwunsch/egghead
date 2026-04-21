---
id: coding/config-30
title: "HealthTeamSync"
description: "Please write a software application called HealthTeamSync that facilitates collaborative health and fitness management among a group of users."
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
source: "marble/configs/coding_configs/config_30.yaml"
---

# HealthTeamSync

Software Development Task:

Please write a software application called HealthTeamSync that facilitates collaborative health and fitness management among a group of users. HealthTeamSync is a platform that enables users to form teams, set shared health and fitness goals, and track individual and team progress. The app provides features for setting personal and team challenges, sharing progress updates, and communicating within the team to stay motivated and achieve collective health and fitness objectives.
1. Implementation requirements:
   - The application should allow users to create and join teams, with each team having a unique name and description.
   - Users should be able to set personal and team health and fitness goals, such as weight loss, muscle gain, or endurance improvement. Goals should include a target value and a deadline.
   - The application should provide a feature for creating and managing personal and team challenges. Challenges should include a title, description, start and end dates, and specific activities or exercises.
   - Users should be able to log their daily activities and progress, which should be visible to other team members. The app should support logging of various metrics such as weight, distance, time, and calories burned.
   - The application should include a communication feature that allows team members to send messages, share tips, and provide encouragement to one another.
   - The application should generate notifications and reminders to keep users engaged and on track with their goals and challenges.
   - The application should provide a dashboard that displays team progress, individual contributions, and overall performance metrics.
   - Comprehensive test cases should be provided to validate the functionality of the application. Test cases should include scenarios for creating and joining teams, setting and tracking goals, logging activities, and using the communication features. Edge cases, such as invalid input and boundary conditions, should also be validated.


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
