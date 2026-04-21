---
id: coding/config-50
title: "TravelMate"
description: "Please write a software application called `TravelMate` that provides personalized travel itineraries and recommendations based on user preferences and travel history."
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
source: "marble/configs/coding_configs/config_50.yaml"
---

# TravelMate

Software Development Task:

Please write a software application called `TravelMate` that provides personalized travel itineraries and recommendations based on user preferences and travel history. TravelMate is a personalization system that helps users plan their trips by suggesting destinations, activities, accommodations, and transportation options tailored to their interests, budget, and travel history.
1. Implementation requirements:
   - The application must allow users to input their travel preferences, including budget, preferred travel dates, type of activities (e.g., cultural, adventure, relaxation), and any dietary restrictions.
   - The system should generate a personalized itinerary that includes a list of recommended destinations, activities, accommodations, and transportation options. Each recommendation should include a brief description, price, and user reviews.
   - The application must provide a feature for users to save and modify their itineraries, including the ability to add or remove items and adjust the schedule.
   - The system should include a test suite with the following test cases: 
- Test case 1: Input valid travel preferences and verify that the generated itinerary is personalized and includes all required elements. 
- Test case 2: Input invalid travel dates (e.g., end date before start date) and verify that the system returns an appropriate error message. 
- Test case 3: Test the save and modify itinerary feature by adding and removing items and verifying that the changes are reflected correctly. 
- Test case 4: Input a user with no travel history and verify that the system still generates a personalized itinerary based on the provided preferences. 
- Test case 5: Test edge cases such as extremely tight budgets or very short travel durations to ensure the system can handle these scenarios gracefully.
   - The application should provide nutritional information for any food-related activities or accommodations, similar to the Personal_Cooking_Coach, to cater to users with dietary restrictions.


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
