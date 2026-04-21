---
id: coding/config-40
title: "Music Collaboration Hub"
description: "Please write a software application called Music_Collaboration_Hub."
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
source: "marble/configs/coding_configs/config_40.yaml"
---

# Music Collaboration Hub

Software Development Task:

Please write a software application called Music_Collaboration_Hub. Music_Collaboration_Hub is a web-based platform that allows multiple users to collaborate in real-time on music projects, including creating loops, analyzing chord progressions, and visualizing soundwaves. The application integrates the functionalities of a loop creator, progression analyzer, and soundwave visualizer, providing a comprehensive toolset for musicians, producers, and enthusiasts to collaborate and enhance their music production and analysis processes.
1. Implementation requirements:
   - The frontend should provide a user-friendly interface with a real-time collaboration feature, allowing multiple users to work on the same project simultaneously. It should include tools for creating musical loops, analyzing chord progressions, and visualizing soundwaves. The interface should support drag-and-drop functionality, real-time updates, and a chat system for communication among collaborators.
   - The backend should handle user authentication, session management, and real-time synchronization of project data across multiple clients. It should support RESTful APIs for data exchange and WebSocket connections for real-time updates. The backend should also include a database to store user profiles, project data, and collaboration history.
   - The database should be designed to efficiently store and retrieve musical data, including loops, chord progressions, and soundwave visualizations. It should support version control for projects to allow users to track changes and revert to previous states. The database should also store user preferences and collaboration settings.
   - The system should include a music processing engine that can analyze audio files and MIDI inputs to extract relevant data for loop creation, chord progression analysis, and soundwave visualization. The engine should be modular and extensible to support future enhancements and additional features.
   - The application should be scalable to handle a large number of concurrent users and projects. It should be designed to run on cloud infrastructure, allowing for easy scaling and maintenance. The system should also be optimized for performance to ensure smooth real-time collaboration and data processing.


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
