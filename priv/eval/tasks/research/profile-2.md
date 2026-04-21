---
id: research/profile-2
title: "Research Collaboration — Profile 2"
description: "Given a paper introduction on CybORG (autonomous cyber operations gym), 5 researcher personas collaborate on a novel research direction."
category: research
difficulty: medium
required_capabilities: [records.read]
personas: ['researcher-p2-1', 'researcher-p2-2', 'researcher-p2-3', 'researcher-p2-4']
dialogue_mode: open
milestones:
  - "Identify overlapping research interests across agents"
  - "Propose a concrete collaborative research direction"
  - "Ground the proposal in cited prior work or empirical observations"
  - "Acknowledge limitations or open questions in the proposal"
  - "Converge on a shared recommendation by end of deliberation"
source: "marble/configs/test_config_research/profile_2.yaml"
---

# Research Collaboration — Profile 2

Dear Research Team,

            You are collaborating to generate a new research idea based on the following Introduction:

            **Introduction**

            Abstract
Autonomous Cyber Operations (ACO) involves the
development of blue team (defender) and red team
(attacker) decision-making agents in adversarial
scenarios. To support the application of machine
learning algorithms to solve this problem, and to
encourage researchers in this ﬁeld to attend to prob-
lems in the ACO setting, we introduce CybORG, a
work-in-progress gym for ACO research. CybORG
features a simulation and emulation environment
with a common interface to facilitate the rapid
training of autonomous agents that can then be
tested on real-world systems. Initial testing demon-
strates the feasibility of this approach.
1Background
Autonomous Cyber Operations (ACO) is concerned with
the defence of computer systems and networks through au-
tonomous decision-making and action. It is particularly
needed where deploying security experts to cover every net-
work and location is becoming increasingly untenable, and
where systems cannot be reliably accessed by human defend-
ers, either due to unreliable communication channels or ad-
versary action.
The ACO domain is challenging to develop artiﬁcial intelli-
gence (AI) approaches for as it combines hard problems from
other domains of AI research. Like game AI, it is adversar-
ial: the effectiveness of a defensive cyber agent is determined
by its ability to respond to an adversary. Like autonomous
robotics, ACO is affected by the ‘reality gap’ [Ibarz et al. ,
2021 ], as simulations of an environment willabstract away
information that could be critical to an agent’s effectiveness.
A further issue for the ACO domain is that the environment
and action set change as cyber security research progresses,
which is far more rapidly than either of the domains discussed
above.
The requirement to handle the varying actions of an adver-
sary, in a complex environment, precludes the use of static
data sets to learn ACO behaviour. A tool for learning in ad-
versarial environments is an AI Gym. AI Gyms such as the
one developed by OpenAI implement reinforcement learning(RL) through direct interaction with a simulation of the prob-
lem. A path to addressing the ‘reality gap’, used in [Tanet
al., 2016 ], is to combine learning on simulations with testing
in a real environment. In this case, the bulk of learning is
conducted on simulated systems. Successful agents are trans-
ferred to the real system to ﬁrstly validate their effectiveness,
and secondly to reﬁne the simulation.
We believe that AI Gyms, that can be validated and re-
ﬁned throughexperiments, the requirements of ACO motivate an in-
tegrated design comprising emulation and simulation modes
to support large scale RL across diverse scenarios.
We have made progress towards implementing this design,
with the ability to spawn and play games either in simula-
tion mode or emulation mode with cloud infrastructure. In
CybORG, we can now train an RL agent in simulation then
test its effectiveness in emulation. TheRelated Work
There are a growing number of cyber security environments
designed for experimentation. A summary of several environ-
ments, with an assessment of how they ﬁt our requirements,
can be found in Table 1.
DETERlab [Mirkovic et al. , 2010 ]is a specialised cy-
ber security experimentation environment based on EMU-
lab[Stoller et al. , 2008 ]. It supports cyber security experi-
mentation through the emulation of hosts and networks. As
it relies on local hardware, DETERlab has limited maximum
network size and takes a signiﬁcant amount of time to reset or
reconﬁgure. VINE [Eskridge et al. , 2015 ], SmallWorld [Fur-
faro et al. , 2018 ]and BRAWL [Corporation, 2018 ]lever-
age cloud-based Infrastructure

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
