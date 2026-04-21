---
id: coding/config-20
title: "MusicMashupBattle"
description: "Please write a program called MusicMashupBattle that allows users to collaborate and compete in creating music mashups."
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
source: "marble/configs/coding_configs/config_20.yaml"
---

# MusicMashupBattle

Software Development Task:

Please write a program called MusicMashupBattle that allows users to collaborate and compete in creating music mashups. MusicMashupBattle is a multiplayer entertainment application that enables users to mix and match different music tracks, apply various effects, and create unique mashups. Users can join public or private rooms, collaborate in real-time to create mashups, and compete to see who can produce the most popular mashup based on user votes.
1. Implementation requirements:
   - Frontend: Develop a user-friendly interface that allows users to select music tracks, apply effects, and preview the mashup. The interface should support real-time collaboration, enabling multiple users to work on the same mashup simultaneously. Implement a chat feature for users to communicate within the room.
   - Backend: Create a server that manages user sessions, room creation, and real-time synchronization of mashup creation. Implement a voting system to allow users to rate mashups and a leaderboard to display the top mashups. Ensure the backend can handle multiple concurrent sessions and data synchronization.
   - Database: Design a database to store user profiles, mashup creations, and voting data. The database should support efficient querying for leaderboards and user history. Implement security measures to protect user data and prevent unauthorized access.
   - Cross-Domain Interaction: Ensure seamless communication between the frontend and backend, particularly for real-time data updates during mashup creation and voting. Implement websockets or similar technology to facilitate low-latency updates and smooth user experience.


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
