# Contributing to FluidVoice

Thanks for taking the time to improve FluidVoice. This repository keeps GitHub Issues focused on actionable work, and uses Discussions for questions, ideas, and early design conversations.

## Before you write code

- **Every PR must link a tracking issue**, including bug fixes, small changes, and documentation updates. Search for an existing issue first; open one if none exists. A Discussion or roadmap item alone does not replace the issue.
- **Major features and UI or UX changes need explicit approval before implementation.** Describe the proposal in an issue and wait for a maintainer or moderator to confirm the scope. Opening an issue or receiving no response is not approval.
- **Major feature requests must start in [Discussions](https://github.com/altic-dev/FluidVoice/discussions/new?category=ideas).** Wait for maintainer or moderator approval, then create or link a tracking issue before starting the PR. Link both the issue and the accepted Discussion in the PR.
- **Keep PRs atomic and include evidence.** Submit one focused fix or change at a time, with a screenshot, image, or video and clear steps that let a maintainer reproduce and verify it.

Agreeing on the direction first helps avoid work that cannot be accepted. Small bug fixes do not need advance design approval, but they still need a linked issue and reproduction evidence.

## AI-assisted contributions

AI-assisted coding is welcome. A human must create the final PR or review and approve it before submission, and take responsibility for the entire change.

- Read the full diff, understand the code, and verify the behavior before requesting review. Be ready to explain your implementation and respond to feedback yourself.
- Check AI-generated explanations, reproduction steps, test claims, and references against what you actually observed. Report checks you did not run; do not present generated claims as verified results.
- Keep the PR description, code comments, and review replies concise and relevant. Remove redundant generated commentary, unrelated suggestions, and repeated explanations. Do not post unsolicited automated PRs or batches of unrelated comments.
- State briefly how AI was used and what you personally reviewed and tested.

**Example:** "Used Claude to draft the fix. I reviewed every changed line, reproduced the bug, tested the fix on macOS [version] / [architecture], and attached before-and-after evidence. I did not test on Intel."

AI use alone is not a reason to reject a contribution. Signs that generated work has not been vetted by a human—such as fabricated test results, irrelevant changes, or an author unable to explain the code—will block review and merging until corrected. Maintainers may close unvetted or spam-like submissions.

## Start with Discussions

Start a GitHub Discussion first when you want to:

- Ask a support question.
- Propose a broad idea or feature.
- Explore a design direction.
- Report behavior that you are not sure is a FluidVoice bug.
- Ask whether a change would be accepted before writing code.

Major feature ideas must begin in the Ideas discussion category. After approval, you or a maintainer must create or link a tracking issue before implementation begins.

## Issues

Issues are for work that maintainers can triage and act on.

Use a bug issue only when you can provide:

- A clear description of the bug.
- Exact reproduction steps.
- Expected behavior and actual behavior.
- FluidVoice version, macOS version, and architecture.
- Logs, crash reports, screenshots, or recordings when relevant.

For an approved major feature, link the accepted Discussion in the tracking issue. For a UI or UX change, record the agreed scope and maintainer or moderator approval in the issue before implementation.

Incomplete bug reports may be labeled `needs reproduction`. If the missing reproduction details are not provided after 14 days, the issue may be closed.

## Pull Requests

Every pull request must link a tracking issue. Before opening a PR:

- Keep the PR focused on one fix or change; split unrelated work into separate PRs.
- Fill out every required section of the PR template.
- Select a type of change.
- Link the tracking issue using `Fixes #123` or `Closes #123` when the PR resolves it, or `Related to #123` for partial work.
- For major features, also link the accepted Discussion. For major features and UI or UX changes, link the maintainer or moderator's approval of the scope.
- Provide exact reproduction or verification steps, expected behavior, and the result after your change.
- Describe what you tested, including the FluidVoice version, macOS version, and Mac architecture. State any checks you could not run.
- Attach a screenshot, image, or video showing the issue and the result. For UI or UX changes, include before-and-after evidence. For non-visual changes, include a screenshot of relevant test results or diagnostic output, plus copyable logs or test output.

Evidence should let a maintainer verify the change without guessing how to reproduce it. Missing evidence or unclear steps can delay review; remove personal information and secrets from attachments.

The `PR Policy` check validates required template information, but a passing check does not replace these contribution requirements or maintainer approval. PRs missing a tracking issue, required approval, or reproduction evidence may be returned for updates or closed. If required template information is still missing after the existing 48-hour correction window, the PR may be closed so maintainers can keep review queues focused.

**These requirements are mandatory, including human review of AI-assisted work. PRs that do not follow them will not be reviewed or merged until they comply, and may be closed. Maintainer review time is limited; please provide the required issue links, approvals, reproduction steps, and evidence before requesting review.**

## Repository Settings

Maintainers should enable GitHub Discussions with these categories:

- Ideas
- Help
- General

Maintainers should require the existing build/test check and the `PR Policy` check before merging to `main`.
