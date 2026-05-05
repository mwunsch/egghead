---
title: Egghead is a note-taking app
section: Background
weight: 40
summary: Why Egghead is a note-taking app, why the notes are plain text, and why the agents work as a loosely-coordinated team rather than a single assistant.
---

Egghead is a note-taking app.

There are some who have already decided that the next interesting thing in software is going to call itself "AI-native" or "agentic" or "the cognitive operating system of the future." Egghead is not those things. Or rather, it is some of those things but only as a consequence of being a note-taking app in 2026.

## The problem with notes

We take notes because notes outlast thinking. Anyone who has kept a notebook, either physical or digital, for any length of time has had the experience of writing something down only to later be unable to find it. You know the note is there, somewhere, but you can't, for the life of you, recall where it was or what it said.

This central challenge of keeping notes gets worse with scale. A single notebook is searchable by hand. Ten notebooks are significantly more challenging. A folder of digital notes can be searched, but only if you remember the exact words you used, which you usually don't because the whole reason you wrote the note in the first place was to externalize the thought so you could stop holding it. The note is supposed to do the remembering for you. Instead it just changed *where* the forgetting occurs.

The work to create a *system* of note-taking has lasted nearly as long as the act of note-taking itself. The Renaissance period had [*commonplace books*](https://en.wikipedia.org/wiki/Commonplace_book). The Index Card was popularized by [Carl Linnaeus](https://en.wikipedia.org/wiki/Carl_Linnaeus) -- a guy with strong opinions about structured information. In the 20th Century an obscure German sociologist named Niklas Luhmann took his note-taking seriously enough to build a card catalog of nearly ninety thousand interlinked notes, which he then used to write more than seventy books and nearly four hundred scholarly articles. The system he extensively used was [Zettelkasten](https://en.wikipedia.org/wiki/Zettelkasten), which became a subject of his own research into systems theory, and prefigured the [Wiki](https://en.wikipedia.org/wiki/History_of_wikis).

The 21st century has produced an entire category of software -- Evernote, Obsidian, Notion, Roam, Bear, Apple Notes, Logseq -- to name just a handful that popped into my head. Each one promising that *this time*, the notes will stay findable. I know I am not alone in having tried more than one of them, and sticking with it for a nontrivial amount of time before finding another shiny object promising untold cognitive reward.

They all work, but they all suffer from the same limitations. No matter how good the search, or how clever the linking, or how disciplined you are about tagging, the system can only ever give back what you put in. The smartest thing in the room is still you.

This isn't a failure of any specific tool, but a structural property of the whole category. The limit on what you can do with a notebook is your own memory of what's in it. Which is, if you're like me, not very good. Which is why I started writing things down in the first place.

### How to write good notes

There is a self-help sub-genre in your nearest global online bookstore dedicated to note-taking systems, and though I have a personal perspective of what makes a good system of notes, I find the more critical thing to answer is *where* the notes are and *how* they are made available to you.

The best answer, as of this writing, is the same answer as it was fifty years ago: a series of files written in [plain text](https://en.wikipedia.org/wiki/Plain_text) on your storage disk. Many popular note-taking software applications tend to use proprietary formats in proprietary databases, accessed only through said proprietary application. Plain text files are the computer world's universal interface, and are a core pillar of the [Unix philosophy](https://cscie2x.dce.harvard.edu/hw/ch01s06.html).

For Egghead, the notes are assumed to live as files in a directory formatted as
either [Markdown](https://en.wikipedia.org/wiki/Markdown) or [Org
Mode](https://orgmode.org) using [Wikilinks](https://en.wikipedia.org/wiki/Help:Wikitext#Wikilinks) to denote connections between them. When we circumscribe our written notes to proprietary formats, we reduce our ability to retrieve them. Which as stated earlier, is already challenging enough due to the limitations of our own memory. Plain text first.

## Why Artificial Intelligence

For most of recent history, the limitations of software notebooks were reflections of the limitations of physical notebooks: limitations of the human operator. Improvements in metadata, indexing, and search are still fundamentally bound by the user: you can only search for a word that has been explicitly written, and traverse relationships over metadata that the user has embedded. Software could not, in any meaningful sense, build a notebook that *read* what you wrote and *engaged* with it as a participant.

Large language models change this. Not because they are intelligent in any deep sense, but because they can read more text than I can hold in my head, and they can produce reasonable language about that text on demand. That is genuinely new.

So the obvious move is to point an AI assistant at your notes and let it go to town.

### The problems with AI in knowledge management

This is what the current generation of AI products is doing. Uploading files to ChatGPT, creating project knowledge in Claude, Notion AI on top of your Notion workspace, Cursor in your codebase... They all share the same shape: there is a knowledge base *over here* and a single AI assistant *over there* and the assistant can occasionally reach over to read from the knowledge base before answering your question.

The most ambitious version of this shape, and the one that pushed me to build something different, is [OpenClaw](https://openclaw.ai). An open-source personal AI assistant that you can run on your own machine, talk to from any messaging app, and connect to your files and tools. It's genuinely good.

But OpenClaw directly demonstrates the limitations of a single AI assistant: it *agrees with you*.

[It has to.](https://www.anthropic.com/research/towards-understanding-sycophancy-in-language-models) There is no structural pressure on it to do otherwise. When you ask it a question, it will give you an answer shaped like the question. You ask a leading question and it follows your lead. The "You're absolutely right!" reflex is both well-trodden joke material as well as real architectural fact: a single agent, optimizing locally for "be helpful" will reliably converge toward whatever the user seems to want to hear. This is the shape of one-on-one assistance.

#### The memory of AI assistants

What happens after a conversation with an AI assistant ends? Increasingly, they remember things from conversation to conversation (which wasn't always the case). OpenClaw, for example, has a [MEMORY.md](https://docs.openclaw.ai/concepts/memory) and workspace for persistence.

The dominant pattern for memory in AI tooling is some flavor of retrieval-augmented generation ([RAG](https://blogs.nvidia.com/blog/what-is-retrieval-augmented-generation/)). Notes and past conversations get chunked into passages, embedded into vectors, and stored. On each new prompt, the [harness](https://www.langchain.com/blog/the-anatomy-of-an-agent-harness) pulls the chunks that look semantically nearest to the question and stuffs them into the model's context window.

In April, a more ambitious variant of the same impulse was articulated in [Andrej Karpathy's LLM Wiki](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f) pattern, where instead of retrieving from raw sources at query time, an LLM agent incrementally compiles your notes into a structured wiki and then queries *that*.

Both of these patterns exhibit the same flaw. In RAG, retrieval is shaped by the prompt and the prompt is shaped by *you*.

RAG works on chunks, not documents -- your essay's argument structure is gone before the agent ever sees it. In the LLM Wiki version, the same bias gets baked in earlier: by the time the wiki entry exists, it's been passed through the agent's filter. The summary is cleaner than the source. That's what makes it a really compelling "memory" product, but not a great note-taking product. Ambiguity in your notes gets edited toward coherence.

So both the shape of a single AI assistant and its memory formation produce a thinking partner who is very capable at creating a confident, well-organized version of what you've already decided you wanted to hear.

This is exactly the limitation of human users that leads many to abandon note-taking or continuously migrate from one note-taking system to the next. The notebook can only return what you remember to retrieve. The single AI assistant with RAG memory can only return what your prompt vocabulary aims at. So the assistant-plus-notes shape, even with modern persistence, has two failure modes that compound: a single agent cannot disagree with itself in any structurally reliable way, and a single agent's memory pulls toward the framing you walked in with. Both failures point at the same fix.

You need more than one, and they need to share notes.

## Multi-Agent Systems

The intuition is straightforward and very human: Teams beat individuals on most kinds of knowledge work, especially the kind where the failure mode is groupthink rather than skill gap. Peer review beats self-review. Code review beats no code review. We already know this about humans. We already build institutions around it. A single perspective on its own work has a structural blind spot and the cure is more perspectives.

Apply that to the notebook problem. If a single agent has a tendency to agree with you, the fix is not to find a better single agent. The fix is to put a *second* agent in the room with a different disposition, and let them disagree with each other where you can watch. The peer review you'd want from a thoughtful colleague, manufactured at the structural level, in real time, on the body of work you actually care about.

Many agentic orchestration frameworks have arrived to multi-agent systems by a different route, but their shape does not lend itself to inherently better results. They default to *coordinator* and *specialists* -- one agent dispatches tasks, others execute, and results aggregate at the top. This is a star topology -- an org-chart fantasy of how teams work.

The [Linux kernel mailing list](https://subspace.kernel.org/vger.kernel.org.html) does not have a dispatcher delegating tasks for execution. An organization that adopts Slack does not have an executive function adjudicating every channel message. Even in environments where you would *expect* a rigid hierarchy -- [like a nuclear submarine](https://davidmarquet.com/books/turn-the-ship-around-book/) -- the strict leader-follower model doesn't always produce the best outcomes. In my own personal experience working in software teams, the teams that work are ones where the coordination is light and the communication is dense.

The recent MAS research bears this out -- graph topologies, where any agent can talk to any other agent, [outperform star and tree shapes](https://arxiv.org/abs/2503.01935) on collaborative tasks.

### The capabilities of agents

Once you commit to a team full of agents working in a shared knowledge store, a security and a quality problem emerge that single-agent systems can (and frequently do) ignore.

"How much should this agent be able to access and perform?" is both a security question and a quality question. It's a security question because, as has been borne out, agents can and will leak internal secrets to external places or perform destructive actions. More agents means more potential for leakage. It's a quality question because agents that can do everything tend to converge. Without distinct role definitions, the disagreement that made a multi-agent architecture useful in the first place dissolves into consensus. Capability scoping is the structural pressure that keeps the room from collapsing into agreement.

This is the [principle of least privilege](https://en.wikipedia.org/wiki/Principle_of_least_privilege) applied to agentic systems. The same reason I, as adjunct faculty, do not have the keys to Columbia University's Network Operations Center. Least privilege improves the quality of the output, because it preserves the structural diversity that makes a team perform better than an individual.

## What is Egghead?

**Egghead is a note-taking app.**

The notes are written as plain-text files in a folder you own.

It uses a loosely-coordinated group of AI agents to continuously read from and contribute to the total knowledge base, producing the most diverse set of inferences about that knowledge by allowing the user to grant each agent a distinct set of capabilities.

Every agent is itself defined as a note, as are the transcripts of their conversations and individual deliberations, giving each note provenance for its creation.

The notes are written as plain text in the filesystem, and the app exposes this and communication with its agents through as many surfaces as possible -- the terminal, the web, MCP, and IRC -- so that your knowledge is not locked behind any one of them.

## The goal of taking notes in Egghead

It is worth restating, we take notes because notes outlast thinking. Simply stated, the goal is to extend our thoughts beyond the storage and time limitations of our own [wetware](https://en.wikipedia.org/wiki/Wetware_(brain)).

The goal is **not** productivity. The goal is **not** to get more done. The goal is not to have your meetings summarized, or your emails triaged, or your tasks auto-prioritized. Those are nice. They are not the point. The point -- the actual, unfashionable, embarrassing-to-say-in-a-funding-pitch point -- is to *get smarter*. To retain more of what you read. To do more with what you retain. To engage with your own past thinking.

Every "AI assistant" on the market is a productivity tool, by which I mean a tool whose purpose is to enable you to do less of a thing and produce more output. A note-taking app built on this premise would exist to *reduce* the time you spend with your notes. I want the opposite. I want a tool that makes you spend *more* time with your notes. That makes the doing of it more rewarding.

Knowledge itself is the outcome. The goal of the practice is -- to use a word that has fallen out of fashion in software but used to be considered the most valuable thing a thinking person could accumulate -- **Wisdom**.

*Ipsa cognitio fructus*
