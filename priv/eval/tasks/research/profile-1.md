---
id: research/profile-1
title: "Research Collaboration — Profile 1"
description: "Given a paper introduction on model merging (DELLA/DARE), 5 researcher personas collaborate to generate a novel research idea."
category: research
difficulty: medium
required_capabilities: [records.read]
personas: ['researcher-p1-1', 'researcher-p1-2', 'researcher-p1-3', 'researcher-p1-4', 'researcher-p1-5']
dialogue_mode: open
milestones:
  - "Identify overlapping research interests across agents"
  - "Propose a concrete collaborative research direction"
  - "Ground the proposal in cited prior work or empirical observations"
  - "Acknowledge limitations or open questions in the proposal"
  - "Converge on a shared recommendation by end of deliberation"
source: "marble/configs/test_config_research/profile_1.yaml"
---

# Research Collaboration — Profile 1

Dear Research Team,

            You are collaborating to generate a new research idea based on the following Introduction:

            **Introduction**

             Introduction
Interactive systems based on general-purpose
LLMs have become widely popular due to their
impressive instruction-following capabilities (Ope-
nAI, 2023). Furthermore, tuning these models on
downstream tasks has been shown to transform
them into domain experts (Rozière et al., 2023;
Luo et al., 2023).
Maintaining separate fine-tuned models for each
task presents several limitations, such as a signif-
icantly higher memory footprint and the inability
to leverage information across tasks, which could
enhance both in-domain and out-of-domain perfor-
mance. As a result, merging different homologousmodels (models fine-tuned from the same back-
bone) is gaining traction for its cost-effectiveness,
knowledge sharing, and space efficiency (Yadav
et al., 2024; Yu et al., 2023). The homologous
models differ from each other in terms of delta pa-
rameters, i.e., the difference between the fine-tuned
model and backbone model parameters.
In this paper, we introduce a novel approach
for merging homologous models, termed Drop and
rEscaLe via samp Ling with m Agnitude ( DELLA ).
This approach consists of three steps: (Step-1) in-
volves delta parameter drops to reduce interfer-
ence among model parameters. We propose MAG-
PRUNE , a novel pruning method that samples delta
parameters based on their magnitudes; (Step-2) fur-
ther reduces interference through sign-based delta
parameter selection; and (Step-3) fuses the selected
delta parameters.
On three different homologous (expert) mod-
els considered for merging (LM, Math, Code) and
their corresponding benchmark datasets (AlpacaE-
val, GSM8K, MBPP), DELLA outperforms base-
line Experiments
We compare the performance of DELLA against
theDARE baseline to show that magnitude sam-
pling improves the selection of delta parameters
to retain and better maintain the model’s task per-
formance. We vary the drop rate pin [0.3, 0.5,
0.7, 0.8, 0.9, 0.91, 0.92, 0.93, 0.94] and apply the
DARE andDELLA to get models after removing the
proportion of delta parameters. We then evaluate
the model’s performance on its corresponding SFT
task. Table 6 shows the comparison between DARE,
random ranking and MAGPRUNE . We performed Results
A.3 Pruning Rate Hyperparameter Search
For Model Merging
Table 7 shows the results of the pruning rate hy-
perparameter search for each merging combination.
While both MAGPRUNE andDARE can maintain
the performance of individual expert model per-
formance up to a high drop rate of 0.9, our find-
ings indicate that a drop rate of 0.5, works best
for LM+Math, Math+Code and LM+Math+Code.
For LM+Code, a drop rate of 0.7 is optimal. Thus,
we can infer that while dropping delta parameters
helps reduce interference during merging, drop-
ping too many parameters may lead to the loss ofinformation useful for effective merging.
Models Drop rate AlpacaEval GSM8K MBPP Average
LM +
Math0.1 0.805 0.599 / 0.702
0.3 0.812 0.629 / 0.721
0.5 0.804 0.645 / 0.724
0.7 0.787 0.611 / 0.699
0.9 0.683 0.455 / 0.570
LM +
Code0.1 0.741 / 0 0.370
0.3 0.770 / 0 0.385
0.5 0.802 / 0.152 0.477
0.7 0.798 / 0.34 0.569
0.9 0.737 / 0.262 0.500
Math +
Code0.1 / 0.619 0.166 0.393
0.3 / 0.618 0.184 0.401
0.5 / 0.626 0.206 0.416
0.7 / 0.633 0.19 0.412
0.9 / 0.622 0.128 0.375
LM +
Math +
Code0.1 0.732 0.545 0.114 0.464
0.3 0.766 0.623 0.302 0.564
0.5 0.794 0.630 0.3 0.575
0.7 0.770 0.622 0.23 0.541
0.9 0.688 0.446 0.128 0.421
Table 7: Drop Rate of parameters against Task perfor-
mance Appendix
A.1 Importance of GPT4-as-a-judge for Math
tasks - Example
Question: Each person in a certain
household consumes 0.2 kg of rice ev-
ery meal. Supposing 5 members of the
household eat rice every lunch and din-
ner, how many weeks will a 42 kg bag of
rice last?
Generated Answer: 1.

            **Your Task**

            1. **Literature Review**: Analyze the Introduction provided and conduct a brief literature review to understand the current state of research in this area.

            2. **Brainstorming**: Collaboratively brainstorm potential research ideas that build upon or address gaps in the Introduction.

            3. **Summarization**: Summarize your collective ideas.

            4. **Formulate a New Research Idea**: Develop a new research proposal in the format of the '5q', defined below:

               **Here is a high-level summarized insight of a research field Machine Learning.**

               **Here are the five core questions:**

               **[Question 1] - What is the problem?**

               Formulate the specific research question you aim to address. Only output one question and do not include any more information.

               **[Question 2] - Why is it interesting and important?**

               Explain the broader implications of solving this problem for the research community.
               Discuss how such a paper will affect future research.
               Discuss how addressing this question could advance knowledge or lead to practical applications.

               **[Question 3] - Why is it hard?**

               Discuss the challenges and complexities involved in solving this problem.
               Explain why naive or straightforward approaches may fail.
               Identify any technical, theoretical, or practical obstacles that need to be overcome. MAKE IT CLEAR.

               **[Question 4] - Why hasn't it been solved before?**

               Identify gaps or limitations in previous research or existing solutions.
               Discuss any barriers that have prevented this problem from being solved until now.
               Explain how your approach differs from or improves upon prior work. MAKE IT CLEAR.

               **[Question 5] - What are the key components of my approach and results?**

               Outline your proposed methodology in detail, including the method, dataset, and metrics that you plan to use.
               Describe the expected outcomes. MAKE IT CLEAR.

            Please work together to produce the '5q' for your proposed research idea.

            Good luck!
