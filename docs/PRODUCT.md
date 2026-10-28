# DeskBar: product notes

How DeskBar was scoped, what was cut, how it's measured, and what's next. It's written down so
contributors can see the reasoning, not just the code.

## The problem

I work at a MacBook Pro with two external monitors. Several times a day I needed to answer a simple
question: is my Mac OK, and what's going on with it? The answer was spread
across four places:

- Activity Monitor for heat and memory
- System Settings for storage
- Control Centre for sound and Focus
- the battery menu for power

And some answers weren't anywhere at all: what's plugged into which port, whether the charger is a
slow one, what's using the camera.

Existing menu bar monitors answer this with more numbers. That works for people who enjoy reading
graphs, but it doesn't answer *is everything OK?* at a glance.

**Who it's for:** Mac laptop users with a desk setup who want to know their Mac is healthy without
becoming its system administrator.

## Principles

1. **Answer first, detail on request.** The top card always gives one verdict: *All good*, or the
   single most important problem. Detail opens in place, one tile at a time.
2. **Show, don't tabulate.** The 3D Mac carries information a list can't: the lid angle, the cable
   on the correct side, monitors appearing when you connect them.
3. **Invisible when closed.** A utility that costs CPU while you aren't looking at it isn't worth
   having. Nothing renders while the panel is closed.
4. **Local by default.** No account and no analytics. Every network call is listed in the README.
5. **Your Mac, not mine.** Anything that only makes sense in one person's home is optional or off.

## Scope: what shipped, and what was cut

| Idea | Decision | Why |
|---|---|---|
| Health verdict, tiles, quick actions | **v1** | The core job. |
| Living 3D Mac (lid, MagSafe, ports, desk view) | **v1** | It's the thing people remember, and it carries real state. |
| History window with charts | **v1**, behind *Open DeskBar* | Useful, but secondary. The panel stays the product. |
| Smart alerts | **v1** | Turns "glance when you remember" into "it tells you". |
| Controls for one particular home setup (a TV, room lighting) | **Cut** | Built and working, but each one only served one user. Keeping them would have made the product about my desk, not yours. |
| Bundling Apple's 3D MacBook | **Not shipped** | It's Apple's model, for personal use. A flat fallback plus a *Show in 3D* download keeps the experience without redistributing it. |

Cutting features that already worked was the hardest call and the right one. A focused product with
one clear job is easier to explain, easier to contribute to and easier to trust.

## How success is measured

| Metric | Target | Now |
|---|---|---|
| Time to answer "is my Mac OK?" | One click, no scrolling | Verdict is the first line of the panel |
| Idle CPU, panel closed | < 1% | ~0–1.5% |
| CPU and memory after days of uptime | Flat | Flat after the fix below (was 50–100% CPU, ~900 MB after 3.5 days) |
| Setup before first value | None | Works on first launch. Permissions are asked only when a feature needs them |
| Network calls | All listed, none for tracking | 4, listed in the README |

If this grows, I'd add opt-in, anonymous answers to two questions: which tiles people open, and
which actions they use. Those decide what earns a place in the panel.

## Case study: the four-day glitch

**Symptom.** After a few days running, DeskBar felt sluggish. It was using 50–100% CPU and about
900 MB of memory, with no window on screen.

**Investigation.**
- A process sample showed the main thread laying out SwiftUI views continuously.
- A heap dump showed 386,000 live Swift Observation objects, and growing.
- Tracing allocations showed where they came from: each time SwiftUI measured a **segmented
  picker**, macOS's own segmented control created an observation object that was never freed.
- The live pages re-measure the layout on every stats refresh (every 2 s). At about 3 objects per
  refresh, that comes to roughly 386,000 over 3.5 days.
- Each new layout pass had to walk every leaked object, so CPU climbed over time.

**Fix.**
- Replaced the three in-content segmented pickers with a lightweight SwiftUI control that looks the
  same.
- Stopped republishing values that hadn't changed, so pages redraw less often.

**Result.** Zero growth over a minute on every page (previously about 80 per minute), CPU around 0%.

**Lesson.** Measure the product as users run it: for days, not for the length of a demo. The
long-running check is now part of how changes are verified.

## How it was built

DeskBar was built by one person with an AI coding agent (Claude Code). I set the direction, defined
what "good" looked like, made the scope calls and reviewed every change against the running app. The
agent wrote and tested the code. Working this way is mostly product work: writing clear problem
statements, setting acceptance criteria and checking evidence before calling something done.

## What's next

- **Settings window:** choose which tiles and actions appear, and set alert thresholds.
- **More Macs:** the 3D model is a 14" MacBook Pro. Detect the model and use the closest match.
- **Distribution:** a signed, notarised build and Homebrew cask, so people don't need to build it.
- **Open questions:** would people pay for a polished version? Is the 3D Mac a reason to install, or
  a reason to stay?
