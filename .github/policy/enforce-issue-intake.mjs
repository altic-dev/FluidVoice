import { readFileSync } from "node:fs";

import { validateBugIssue } from "./github-policy.mjs";
import {
  addLabels,
  ensureLabel,
  githubRequest,
  paginate,
  removeLabel,
  repoContext,
  upsertIssueComment,
} from "./github-api.mjs";

const BUG_MARKER = "<!-- fluidvoice-bug-intake -->";
const STALE_MARKER = "<!-- fluidvoice-stale-repro -->";
const STALE_REPRODUCTION_DAYS = 14;

const LABELS = {
  needsReproduction: {
    name: "needs reproduction",
    color: "D93F0B",
    description: "Bug report needs enough detail to reproduce.",
  },
};

function eventPayload() {
  return JSON.parse(readFileSync(process.env.GITHUB_EVENT_PATH, "utf8"));
}

function missingFieldsText(fields) {
  return fields.map((field) => `- ${field}`).join("\n");
}

async function existingBugWarningComment(context, issueNumber) {
  const comments = await paginate(
    `/repos/${context.owner}/${context.repo}/issues/${issueNumber}/comments`,
  );
  return comments.find((comment) => comment.body?.includes(BUG_MARKER));
}

async function enforceBugIssue(context, issue) {
  const result = validateBugIssue(issue.body ?? "");

  if (result.ok) {
    await removeLabel(context, issue.number, LABELS.needsReproduction.name);
    return;
  }

  await addLabels(context, issue.number, [LABELS.needsReproduction.name]);
  await upsertIssueComment(
    context,
    issue.number,
    BUG_MARKER,
    [
      "This bug report is missing information required for maintainers to reproduce it.",
      "",
      "Please update the issue with:",
      missingFieldsText(result.missing),
      "",
      `Issues still missing reproduction details after ${STALE_REPRODUCTION_DAYS} days may be closed.`,
    ].join("\n"),
  );
}

async function closeStaleReproductionIssues(context) {
  const staleBefore = new Date(
    Date.now() - STALE_REPRODUCTION_DAYS * 24 * 60 * 60 * 1000,
  )
    .toISOString()
    .slice(0, 10);
  const query = encodeURIComponent(
    `repo:${context.owner}/${context.repo} is:issue is:open label:"${LABELS.needsReproduction.name}" updated:<${staleBefore}`,
  );
  const results = await githubRequest("GET", `/search/issues?q=${query}&per_page=100`);

  for (const issue of results.items) {
    const warningComment = await existingBugWarningComment(context, issue.number);
    if (!warningComment) continue;

    await upsertIssueComment(
      context,
      issue.number,
      STALE_MARKER,
      [
        `Closing this issue because it has been labeled \`needs reproduction\` for at least ${STALE_REPRODUCTION_DAYS} days without the missing reproduction details.`,
        "",
        "If you can still reproduce the problem, please open a new bug report with exact steps, expected behavior, actual behavior, app version, macOS version, and architecture.",
      ].join("\n"),
    );
    await githubRequest("PATCH", `/repos/${context.owner}/${context.repo}/issues/${issue.number}`, {
      state: "closed",
      state_reason: "not_planned",
    });
  }
}

async function main() {
  const context = repoContext();
  await Promise.all(Object.values(LABELS).map((label) => ensureLabel(context, label)));

  const eventName = process.env.GITHUB_EVENT_NAME;
  if (eventName === "schedule" || eventName === "workflow_dispatch") {
    await closeStaleReproductionIssues(context);
    return;
  }

  const event = eventPayload();
  const issue = event.issue;
  if (!issue || issue.pull_request) return;

  const warningComment = await existingBugWarningComment(context, issue.number);
  if (event.action !== "opened" && !warningComment) return;

  const labels = issue.labels.map((label) =>
    typeof label === "string" ? label : label.name,
  );

  if (labels.includes("bug")) {
    await enforceBugIssue(context, issue);
  }
}

await main();
