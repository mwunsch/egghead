---
id: coding/config-100
title: "VideoCollaborationSuite"
description: "Please write a program called VideoCollaborationSuite."
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
source: "marble/configs/coding_configs/config_100.yaml"
---

# VideoCollaborationSuite

Software Development Task:

Please write a program called VideoCollaborationSuite. VideoCollaborationSuite is a collaborative video editing application that allows multiple users to work together on a video project in real-time. It provides tools for trimming, synchronizing subtitles, and adjusting playback speed, and supports real-time communication and feedback among team members.
1. Implementation requirements:
   - The application must support multiple users editing a video simultaneously, with real-time updates and synchronization of changes.
   - It should include a feature for automatic subtitle synchronization, allowing users to upload a video and subtitle file, and automatically align the subtitles with the video content. Users should be able to manually adjust the synchronization if needed.
   - The application must provide a playback speed adjustment tool, allowing users to change the speed of the video playback for precise editing and review.
   - The system should include a chat feature for real-time communication among users, enabling them to discuss and coordinate their editing activities.
   - The application should support version control, allowing users to save different versions of the video and revert to previous states if necessary.
   - The system should dynamically adapt to user feedback, such as suggestions for subtitle adjustments or playback speed changes, and allow for seamless collaboration and iterative improvements.


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
