---
id: coding/config-60
title: "BookVerse"
description: "Please write a software application called BookVerse that integrates the functionalities of quote discovery, reading progress management, and book review tracking."
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
source: "marble/configs/coding_configs/config_60.yaml"
---

# BookVerse

Software Development Task:

Please write a software application called BookVerse that integrates the functionalities of quote discovery, reading progress management, and book review tracking. BookVerse is a comprehensive platform for book enthusiasts that allows users to discover and share inspiring quotes, track their reading progress, and write detailed reviews for the books they read.
1. Implementation requirements:
   - 1. **Quote Discovery Module**: Develop a feature that allows users to search for and discover quotes from books. This module should include functionalities to search by book title, author, and keyword. Users should be able to save their favorite quotes and share them on social media platforms. This module must be completed before the User Profile Module can be integrated.
   - 2. **Reading Progress Management Module**: Implement a system where users can create profiles and manage their reading progress. This should include adding books to a virtual bookshelf, setting reading goals, and tracking the number of pages or chapters read. Users should be able to mark books as 'read' or 'currently reading.' This module must be completed before the Book Review Module can be integrated.
   - 3. **Book Review Module**: Create a feature that allows users to write and rate reviews for the books they have read. The module should provide a user-friendly interface for inputting and updating reviews, and it should offer search and filter functionalities to help users find specific books and reviews. This module depends on the completion of the User Profile Module and the Reading Progress Management Module.


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
